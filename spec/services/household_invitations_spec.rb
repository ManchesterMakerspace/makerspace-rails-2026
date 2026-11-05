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
      expect { invite('Second@Example.com') }.to have_enqueued_job(HouseholdInvitationMailJob)

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

    it 'sends the email through a job that does not log its arguments, so the token stays out of the log' do
      log = StringIO.new
      original = ActiveJob::Base.logger
      ActiveJob::Base.logger = Logger.new(log)
      begin
        invite
        invitation_id, raw = ActiveJob::Base.queue_adapter.enqueued_jobs.last['arguments']
        HouseholdInvitationMailJob.perform_now(invitation_id, raw)
      ensure
        ActiveJob::Base.logger = original
      end

      expect(raw).to match(/\A[\w-]{43}\z/)
      expect(HouseholdInvitationMailJob.log_arguments).to be(false)
      expect(log.string).to include('HouseholdInvitationMailJob')
      expect(log.string).not_to include(raw)
    end

    it 'does not store the token, only its digest' do
      invite
      invitation = HouseholdInvitation.last

      expect(invitation.token_digest).to match(/\A\h{64}\z/)
      expect(invitation.attributes.values.map(&:to_s)).not_to include(a_string_matching(/\A[\w-]{43}\z/))
    end

    it 'inviting the same address again resends the same invitation without taking another seat' do
      first = invite
      first_digest = first.token_digest
      clear_household_invite_cooldown
      second = invite

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
      clear_household_invite_cooldown
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
      clear_household_invite_cooldown

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

    it 'names the joining adult once in the audit message' do
      described_class.accept!(member: second, token: raw)

      expect(Service::AuditLogger).to have_received(:log).with(hash_including(
        event_type: 'household_member_added',
        message_details: "#{second.fullname} joined by invitation from #{primary.fullname}"
      ))
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

  describe 'send limits' do
    it 'refuses a second email to the same address within a minute, on both the invite and the resend path' do
      invitation = invite('second@example.com')

      expect { invite('second@example.com') }.to raise_error(::Error::TooManyRequests, /Wait a minute/)
      expect { described_class.resend!(invitation, primary: primary) }.to raise_error(::Error::TooManyRequests, /Wait a minute/)
      expect(invitation.reload.sent_count).to eq(1)
    end

    it 'a refused send leaves the existing link working' do
      invitation = invite('second@example.com')
      digest = invitation.reload.token_digest

      expect { described_class.resend!(invitation, primary: primary) }.to raise_error(::Error::TooManyRequests)
      expect(invitation.reload.token_digest).to eq(digest)
    end

    it 'allows another send once the cooldown has passed' do
      invitation = invite('second@example.com')
      clear_household_invite_cooldown

      expect { described_class.resend!(invitation, primary: primary) }.not_to raise_error
    end

    it 'caps the emails one sender can send in a day, across recipients' do
      stub_const('HouseholdInviteLimit::PER_SENDER_PER_DAY', 2)
      2.times { |n| HouseholdInviteLimit.claim!(sender_id: primary.id, recipient_email: "r#{n}@example.com") }

      expect { HouseholdInviteLimit.claim!(sender_id: primary.id, recipient_email: 'r9@example.com') }
        .to raise_error(::Error::TooManyRequests, /today's limit/)
    end

    it 'caps the emails one address can receive in a day, across senders' do
      stub_const('HouseholdInviteLimit::PER_RECIPIENT_PER_DAY', 2)
      2.times { HouseholdInviteLimit.claim!(sender_id: BSON::ObjectId.new, recipient_email: 'Same@Example.com') }

      expect { HouseholdInviteLimit.claim!(sender_id: BSON::ObjectId.new, recipient_email: 'same@example.com') }
        .to raise_error(::Error::TooManyRequests, /that address today/)
    end

    it 'does not count a refused send, so a cooldown does not use up the daily cap' do
      stub_const('HouseholdInviteLimit::PER_SENDER_PER_DAY', 2)
      sender = BSON::ObjectId.new
      HouseholdInviteLimit.claim!(sender_id: sender, recipient_email: 'a@example.com')
      expect { HouseholdInviteLimit.claim!(sender_id: sender, recipient_email: 'a@example.com') }.to raise_error(::Error::TooManyRequests, /Wait a minute/)

      expect { HouseholdInviteLimit.claim!(sender_id: sender, recipient_email: 'b@example.com') }.not_to raise_error
    end

    it 'keeps no email address in the Redis key names' do
      HouseholdInviteLimit.claim!(sender_id: primary.id, recipient_email: 'private@example.com')

      keys = REDIS.scan_each(match: 'household_invite_*').to_a
      expect(keys).not_to be_empty
      expect(keys.join).not_to include('private@example.com')
    end

    it 'does not create a household or an invitation when the send is refused' do
      stub_const('HouseholdInviteLimit::PER_SENDER_PER_DAY', 0)

      expect { invite('second@example.com') }.to raise_error(::Error::TooManyRequests)
      expect(Group.where(groupName: primary.id.to_s).count).to eq(0)
      expect(HouseholdInvitation.count).to eq(0)
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

    context 'when the invitation can no longer be used' do
      def preview_for(email = 'second@example.com')
        described_class.preview(member: invitee(email: email), token: raw)
      end

      def expect_redacted(result, status)
        expect(result).to include(status: status, primary_name: nil, household_address: nil, address_matches: false, payment_accepted: false)
        expect(result.to_s).not_to include('12 Main St, 03101 ')
        expect(result[:household_address]).to be_nil
      end

      it 'reveals no household details once it was cancelled, even after the primary changes address' do
        raw
        described_class.revoke!(invitation.reload, primary: primary)
        primary.update_attributes!(address_street: '99 Moved Ave')

        result = preview_for
        expect_redacted(result, 'revoked')
        expect(result.to_s).not_to include('99 Moved Ave')
        expect(result.to_s).not_to include(primary.fullname)
      end

      it 'reveals no household details once it has expired' do
        raw
        invitation.update!(expires_at: 1.minute.ago)

        expect_redacted(preview_for, 'expired')
      end

      it 'reveals no household details after it was used and the member was later removed' do
        second = invitee(email: 'second@example.com')
        described_class.accept!(member: second, token: raw)
        group = Group.find_by(groupName: primary.id.to_s)
        second.update_attributes!(groupName: nil)
        group.reload

        expect_redacted(described_class.preview(member: second.reload, token: raw), 'accepted')
      end

      it 'still tells the wrong signed-in account nothing but the masked email' do
        raw
        described_class.revoke!(invitation.reload, primary: primary)

        expect { preview_for('nobody@example.com') }.to raise_error(::Error::Forbidden, /s\*+@example.com/)
      end

      it 'the public lookup of a cancelled, expired or used link names nobody and shows no email' do
        raw
        described_class.revoke!(invitation.reload, primary: primary)
        revoked = described_class.public_info(raw)
        invitation.update!(status: 'pending', expires_at: 1.minute.ago)
        expired = described_class.public_info(raw)

        expect(revoked).to include(status: 'revoked', inviter_name: nil, invited_email: nil)
        expect(revoked.keys).to contain_exactly(:status, :inviter_name, :invited_email, :expires_at)
        expect(expired).to include(status: 'expired', inviter_name: nil, invited_email: nil)
      end
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
