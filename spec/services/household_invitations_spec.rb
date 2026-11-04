require 'rails_helper'

RSpec.describe HouseholdInvitations do
  let(:plan) { 'household-membership-one-month-recurring' }
  let(:address) { { address_street: '12 Main St', address_postal_code: '03101' } }
  let(:primary) { create(:member, address.merge(expirationTime: nil)) }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Service::AuditLogger).to receive(:log)
    allow(Service::SlackConnector).to receive(:enque_message)
    pay_household(primary)
  end

  def pay_household(member, settled: true)
    create(:invoice, member: member, resource_id: member.id.to_s, resource_class: 'member', plan_id: plan,
                     settled_at: settled ? Time.now : nil)
  end

  def invitee(attrs = {})
    create(:member, address.merge(expirationTime: nil).merge(attrs))
  end

  def invite(email = 'second@example.com', who = primary)
    described_class.invite!(primary: who, email: email)
  end

  # The raw token is only ever in the email, so a test rotates it to get one.
  def token_for(invitation)
    invitation.issue_token!
  end

  describe '.eligibility' do
    it 'allows a primary whose household payment is accepted' do
      expect(described_class.eligibility(primary)).to eq(allowed: true, reason: nil)
    end

    it 'says why when it is not allowed' do
      expect(described_class.eligibility(create(:member))[:reason]).to match(/not on a household plan/)

      unpaid = create(:member)
      pay_household(unpaid, settled: false)
      expect(described_class.eligibility(unpaid)[:reason]).to match(/payment has not been accepted yet/)
    end

    it 'does not allow a secondary to invite' do
      group = Group.create!(groupName: primary.id.to_s, groupRep: primary.fullname, expiry: primary.expirationTime)
      primary.update_attributes!(groupName: primary.id.to_s)
      secondary = create(:member, address)
      group.add_subordinate(secondary)

      expect(described_class.eligibility(secondary.reload)[:reason]).to match(/Only the primary/)
    end

    it 'stops when the household is full, counting open invitations' do
      invite('one@example.com')

      expect(described_class.eligibility(primary.reload)).to eq(allowed: false, reason: 'Your household is full (2 of 2 adults).')
    end

    it 'is not allowed once the household payment was refunded or the paid time ran out' do
      Invoice.where(resource_id: primary.id.to_s).first.update!(refunded: true)

      expect(described_class.eligibility(primary)[:allowed]).to be(false)
    end
  end

  describe '.invite!' do
    it 'creates the household on the first invitation, holds a seat for 14 days and emails the typed address' do
      expect { invite('Second@Example.com') }.to have_enqueued_mail(MemberMailer, :household_invitation)

      group = Group.find_by(groupName: primary.id.to_s)
      invitation = HouseholdInvitation.last
      expect(group).to be_present
      expect(primary.reload.groupName).to eq(primary.id.to_s)
      expect(invitation.invited_email).to eq('second@example.com')
      expect(invitation.status).to eq('pending')
      expect(invitation.expires_at).to be_within(1.minute).of(14.days.from_now)
      expect(invitation.sent_count).to eq(1)
      expect(group.seats_used).to eq(2)
      expect(Service::AuditLogger).to have_received(:log).with(hash_including(event_type: 'household_created'))
      expect(Service::AuditLogger).to have_received(:log).with(hash_including(event_type: 'household_invitation_sent'))
    end

    it 'does not store the token, only its digest' do
      invite
      invitation = HouseholdInvitation.last

      expect(invitation.token_digest).to match(/\A\h{64}\z/)
      expect(invitation.attributes.values.map(&:to_s)).not_to include(a_string_matching(/\A[\w-]{43}\z/))
    end

    it 'inviting the same address again resends the same invitation without taking another seat' do
      first = invite
      second = invite
      first_digest = first.token_digest

      expect(second.id).to eq(first.id)
      expect(HouseholdInvitation.count).to eq(1)
      expect(second.reload.sent_count).to eq(2)
      expect(second.token_digest).not_to eq(first_digest)
      expect(Service::AuditLogger).to have_received(:log).with(hash_including(event_type: 'household_invitation_resent'))
    end

    it 'refuses a bad address, the primary\'s own address, and a full household' do
      expect { invite('not an email') }.to raise_error(::Error::UnprocessableEntity, /valid email/)
      expect { invite(primary.email) }.to raise_error(::Error::UnprocessableEntity, /your own email/)
      invite('one@example.com')
      expect { invite('two@example.com') }.to raise_error(::Error::UnprocessableEntity, /household is full/)
    end

    it 'lets a household that covers three invite two people' do
      create(:invoice_option, plan_id: plan, household_size: 3)

      expect { invite('one@example.com'); invite('two@example.com') }.not_to raise_error
      expect { invite('three@example.com') }.to raise_error(::Error::UnprocessableEntity, /household is full \(3 of 3/)
    end

    it 'refuses before the household payment is accepted' do
      unpaid = create(:member)
      pay_household(unpaid, settled: false)

      expect { invite('x@example.com', unpaid) }.to raise_error(::Error::UnprocessableEntity, /payment has not been accepted/)
    end

    it 'refuses someone who already has a subscription or paid time, without telling the primary their dates' do
      subscribed = invitee(subscription_id: 'sub_1', email: 'subscribed@example.com')
      paid = invitee(expirationTime: (Time.now + 30.days).to_i * 1000, email: 'paid@example.com')

      [subscribed, paid].each do |person|
        expect { invite(person.email) }.to raise_error(::Error::UnprocessableEntity, /already has a membership that has not ended yet/) { |error|
          expect(error.message).not_to match(/\d{4}/)
        }
      end
      expect(HouseholdInvitation.count).to eq(0)
    end

    it 'refuses someone already in a household' do
      other_primary = create(:member, address)
      other_primary.update_attributes!(groupName: other_primary.id.to_s)
      member = create(:member, address.merge(groupName: other_primary.id.to_s, email: 'taken@example.com'))

      expect { invite(member.email) }.to raise_error(::Error::UnprocessableEntity, /already part of a household/)
    end

    it 'invites an existing account that has no membership time and no subscription' do
      existing = invitee(email: 'existing@example.com')

      expect { invite(existing.email) }.not_to raise_error
    end
  end

  describe '.revoke! and .resend!' do
    let!(:invitation) { invite }

    it 'revoking cancels the link and frees the seat' do
      raw = token_for(invitation)
      described_class.revoke!(invitation, primary: primary)

      expect(invitation.reload.status).to eq('revoked')
      expect(Group.find_by(groupName: primary.id.to_s).seats_used).to eq(1)
      expect(Service::AuditLogger).to have_received(:log).with(hash_including(event_type: 'household_invitation_revoked'))
      expect { described_class.accept!(member: invitee(email: invitation.invited_email), token: raw) }.to raise_error(::Error::UnprocessableEntity, /cancelled/)
      expect { invite('other@example.com') }.not_to raise_error
    end

    it 'resending gives a new link and the old one stops working' do
      old = token_for(invitation)
      new = described_class.resend!(invitation, primary: primary) && token_for(invitation)

      expect(HouseholdInvitation.find_by_token(old)).to be_nil
      expect(HouseholdInvitation.find_by_token(new)).to eq(invitation)
    end

    it 'only the household primary can revoke or resend' do
      stranger = create(:member)

      expect { described_class.revoke!(invitation, primary: stranger) }.to raise_error(::Error::Forbidden)
      expect { described_class.resend!(invitation, primary: stranger) }.to raise_error(::Error::Forbidden)
    end

    it 'a resend after the 14 days refreshes the window' do
      invitation.update!(expires_at: 1.day.ago)
      expect(invitation.reload.expired?).to be(true)

      described_class.resend!(invitation, primary: primary)

      expect(invitation.reload.open?).to be(true)
      expect(invitation.expires_at).to be_within(1.minute).of(14.days.from_now)
    end

    it 'cannot revoke or resend an invitation that was already accepted' do
      raw = token_for(invitation)
      described_class.accept!(member: invitee(email: invitation.invited_email), token: raw)

      expect { described_class.revoke!(invitation.reload, primary: primary) }.to raise_error(::Error::UnprocessableEntity, /already accepted/)
      expect { described_class.resend!(invitation.reload, primary: primary) }.to raise_error(::Error::UnprocessableEntity, /already accepted/)
    end
  end

  describe '.accept!' do
    let!(:invitation) { invite('second@example.com') }
    let(:raw) { token_for(invitation) }
    let(:second) { invitee(email: 'second@example.com') }

    it 'links the invited person, follows the household expiry, and tells both adults' do
      primary.update_attributes!(expirationTime: (Time.now + 20.days).to_i * 1000)
      group = Group.find_by(groupName: primary.id.to_s)
      group.update_expiration(primary.reload.expirationTime)

      expect { described_class.accept!(member: second, token: raw) }
        .to have_enqueued_mail(MemberMailer, :household_joined).twice

      expect(second.reload.groupName).to eq(primary.id.to_s)
      expect(second.expirationTime).to eq(primary.reload.expirationTime)
      expect(invitation.reload.status).to eq('accepted')
      expect(invitation.accepted_member_id).to eq(second.id)
      expect(group.reload.seats_used).to eq(2)
      expect(Service::AuditLogger).to have_received(:log).with(hash_including(event_type: 'household_member_added',
        after_snapshot: hash_including(source: 'invitation')))
    end

    it 'requires the signed-in account to use the invited email, masking it' do
      other = invitee(email: 'someone.else@example.com')

      expect { described_class.accept!(member: other, token: raw) }.to raise_error(::Error::Forbidden, /s\*+@example.com/)
      expect(other.reload.groupName).to be_nil
    end

    it 'refuses an unknown, used, cancelled or expired link' do
      expect { described_class.accept!(member: second, token: 'nonsense') }.to raise_error(::Error::UnprocessableEntity, /not valid/)

      token = raw
      invitation.update!(expires_at: 1.minute.ago)
      expect { described_class.accept!(member: second, token: token) }.to raise_error(::Error::UnprocessableEntity, /expired.*send you a new one/)
    end

    it 'cannot be used twice' do
      described_class.accept!(member: second, token: raw)

      expect { described_class.accept!(member: second.reload, token: raw) }.to raise_error(::Error::UnprocessableEntity, /already used/)
    end

    it 'refuses a different address and says what to fix' do
      mismatched = create(:member, email: 'second@example.com', address_street: '99 Other Rd', address_postal_code: '03101', expirationTime: nil)

      expect { described_class.accept!(member: mismatched, token: raw) }
        .to raise_error(::Error::UnprocessableEntity, /Address mismatch: your address \(99 Other Rd, 03101\).*\(12 Main St, 03101\).*Update your address on your profile, then press Join again/)
      expect(invitation.reload.status).to eq('pending')
    end

    it 'accepts a forgiving address match' do
      loose = create(:member, email: 'second@example.com', address_street: '12 main street apt 4', address_postal_code: '03101-0001', expirationTime: nil)

      expect { described_class.accept!(member: loose, token: raw) }.not_to raise_error
    end

    it 'refuses while the household payment is not accepted, and works again once it is' do
      Invoice.where(resource_id: primary.id.to_s).update_all(settled_at: nil)

      expect { described_class.accept!(member: second, token: raw) }.to raise_error(::Error::UnprocessableEntity, /payment has not been accepted/)

      Invoice.where(resource_id: primary.id.to_s).update_all(settled_at: Time.now)
      expect { described_class.accept!(member: second, token: raw) }.not_to raise_error
    end

    it 'blocks a subscriber with the date their paid time ends, and a paid-up member with the date it expires' do
      expires = Time.now + 30.days
      subscriber = invitee(email: 'second@example.com', subscription_id: 'sub_1', expirationTime: expires.to_i * 1000)

      expect { described_class.accept!(member: subscriber, token: raw) }
        .to raise_error(::Error::UnprocessableEntity, /active subscription\. Cancel it.*after your paid time ends on #{expires.strftime('%B %-d, %Y')}.*send the invitation again/)

      subscriber.update!(subscription_id: nil)
      expect { described_class.accept!(member: subscriber, token: raw) }
        .to raise_error(::Error::UnprocessableEntity, /Your membership runs until #{expires.strftime('%B %-d, %Y')}.*after it expires/)
    end

    it 'lets someone join once their paid time has ended' do
      lapsed = invitee(email: 'second@example.com', expirationTime: (Time.now - 3.days).to_i * 1000)

      expect { described_class.accept!(member: lapsed, token: raw) }.not_to raise_error
    end

    it 'refuses someone already in a household' do
      other_primary = create(:member, address)
      other_primary.update_attributes!(groupName: other_primary.id.to_s)
      second.update_attributes!(groupName: other_primary.id.to_s)

      expect { described_class.accept!(member: second.reload, token: raw) }.to raise_error(::Error::UnprocessableEntity, /already part of a household/)
    end
  end

  describe 'a reversed payment' do
    it 'stops new invitations and acceptance, and the secondary expiry follows the primary' do
      invitation = invite
      second = invitee(email: invitation.invited_email)
      described_class.accept!(member: second, token: token_for(invitation))
      group = Group.find_by(groupName: primary.id.to_s)

      future = (Time.now + 20.days).to_i * 1000
      primary.set(expirationTime: future)
      group.reload.update_expiration(future)
      expect(second.reload.expirationTime).to eq(future)
      expect(described_class.eligibility(primary.reload)[:allowed]).to be(false) # household full, payment accepted

      # the payment is refunded and the paid time rolled back
      Invoice.where(resource_id: primary.id.to_s).first.update!(refunded: true)
      past = (Time.now - 1.day).to_i * 1000
      primary.set(expirationTime: past)
      group.reload.update_expiration(past)

      expect(group.reload.payment_accepted?).to be(false)
      expect(described_class.eligibility(primary.reload)[:reason]).to match(/payment has not been accepted/)
      expect(second.reload.expirationTime).to eq(past)
      expect(second.groupName).to eq(primary.id.to_s)
    end

    it 'a new invitation cannot be accepted until the payment is accepted again' do
      invitation = invite
      raw = token_for(invitation)
      Invoice.where(resource_id: primary.id.to_s).first.update!(refunded: true)

      expect { described_class.accept!(member: invitee(email: invitation.invited_email), token: raw) }
        .to raise_error(::Error::UnprocessableEntity, /payment has not been accepted/)
    end
  end

  describe '.public_info and .preview' do
    let!(:invitation) { invite('second@example.com') }
    let(:raw) { token_for(invitation) }

    it 'the public lookup reveals only the inviter, the invited email and the expiry' do
      info = described_class.public_info(raw)

      expect(info.keys).to contain_exactly(:status, :inviter_name, :invited_email, :expires_at)
      expect(info[:inviter_name]).to eq("#{primary.firstname} #{primary.lastname[0]}.")
      expect(info[:invited_email]).to eq('second@example.com')
      expect(described_class.public_info('nonsense')).to be_nil
    end

    it 'the signed-in invitee also sees the address they must match and whether they match' do
      preview = described_class.preview(member: invitee(email: 'second@example.com'), token: raw)

      expect(preview).to include(household_address: '12 Main St, 03101', address_matches: true, payment_accepted: true, blocked_reason: nil)
    end

    it 'does not show the address to a different signed-in account' do
      expect { described_class.preview(member: invitee(email: 'nobody@example.com'), token: raw) }.to raise_error(::Error::Forbidden)
    end
  end

  describe '.state_for' do
    it 'describes a primary with seats and open invitations, and an unattached member with an invitation waiting' do
      invitation = invite('second@example.com')
      state = described_class.state_for(primary.reload)

      expect(state).to include(role: 'primary', can_invite: false, plan_size: 2)
      expect(state[:household]).to include(size: 2, seats_used: 2, payment_accepted: true)
      expect(state[:household][:invitations]).to contain_exactly(hash_including(email: 'second@example.com', status: 'pending'))
      expect(described_class.state_for(invitee(email: invitation.invited_email))).to include(role: nil, invited_to_a_household: true)
    end

    it 'shows a secondary only their primary, with no invitation list' do
      invitation = invite
      second = invitee(email: invitation.invited_email)
      described_class.accept!(member: second, token: token_for(invitation))
      state = described_class.state_for(second.reload)

      expect(state).to include(role: 'secondary', can_invite: false)
      expect(state[:household]).not_to have_key(:invitations)
      expect(state[:household][:primary]).to include(name: primary.fullname)
    end
  end
end
