require 'rails_helper'

RSpec.describe Service::SlackUserSync do
  describe '.sync_single' do
    let!(:member) { create(:member, email: 'member@example.com') }
    let(:client) { double('Slack client') }
    let(:response) do
      {
        'user' => {
          'id' => 'U123',
          'name' => 'member',
          'real_name' => 'Member Name',
          'profile' => { 'email' => member.email, 'real_name' => 'Member Name' }
        }
      }
    end

    before do
      allow(Service::SlackConnector).to receive(:api_token_present?).and_return(true)
      allow(Service::SlackConnector).to receive(:client).and_return(client)
      allow(client).to receive(:users_info).with(user: 'U123').and_return(response)
      allow(Service::SlackProfileSync).to receive(:sync_one)
      allow(Service::AuditLogger).to receive(:log)
      allow(Service::MemberProvisioning).to receive(:invite_slack)
    end

    it 'reactivates a normally invalidated identity instead of creating a duplicate Slack ID' do
      identity = SlackUser.create!(member: member, slack_id: 'U123', slack_email: member.email)
      SlackUser.collection.find(_id: identity.id).update_one(
        '$set' => { invalidated_at: Time.current, invalidation_reason: 'slack_user_deleted' }
      )

      expect(described_class.sync_single('U123')).to eq(member)
      expect(SlackUser.find(identity.id).invalidated_at).to be_nil
    end

    it 'does not reactivate an identity quarantined after a member email change' do
      identity = SlackUser.create!(slack_id: 'U123', slack_email: member.email)
      SlackUser.collection.find(_id: identity.id).update_one(
        '$set' => { invalidated_at: Time.current, invalidation_reason: 'member_email_changed' }
      )

      expect(described_class.sync_single('U123')).to be_nil
      expect(SlackUser.unscoped.find(identity.id).invalidated_at).to be_present
    end

    it 'preserves an established member link and audits a changed Slack email' do
      other_member = create(:member, email: 'other@example.com')
      identity = SlackUser.create!(member: member, slack_id: 'U123', slack_email: member.email)
      response['user']['profile']['email'] = other_member.email

      expect(described_class.sync_single('U123')).to eq(member)
      expect(SlackUser.find(identity.id)).to have_attributes(
        member_id: member.id,
        slack_email: other_member.email
      )
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(
          event_type: 'slack_email_mismatch',
          resource_id: member.id,
          subject: member,
          field_changes: {
            'slack_email' => [member.email, other_member.email]
          },
          slack_channel: Service::SlackConnector.logs_channel,
          message_details: /established Member link was preserved/i
        )
      )
    end

    it 'does not reactivate a tombstone when the member already has a different active identity' do
      active_identity = SlackUser.create!(member: member, slack_id: 'UACTIVE', slack_email: member.email)
      tombstone = SlackUser.create!(slack_id: 'U123', slack_email: 'stale-u123@example.com')
      SlackUser.collection.find(_id: tombstone.id).update_one(
        '$set' => { invalidated_at: Time.current, invalidation_reason: 'slack_user_deleted' }
      )

      result = nil
      expect { result = described_class.sync_single('U123') }.not_to raise_error

      expect(result).to be_nil
      expect(SlackUser.unscoped.find(tombstone.id).invalidated_at).to be_present
      expect(SlackUser.find(active_identity.id).slack_id).to eq('UACTIVE')
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(
          event_type: 'slack_identity_conflict',
          resource_id: member.id,
          message_details: /already has a different active Slack identity/i
        )
      )
    end

    it 'does not abort or transfer either link when the changed email already has a Slack identity' do
      other_member = create(:member, email: 'other@example.com')
      identity = SlackUser.create!(member: member, slack_id: 'U123', slack_email: member.email)
      other_identity = SlackUser.create!(
        member: other_member,
        slack_id: 'UOTHER',
        slack_email: other_member.email
      )
      response['user']['profile']['email'] = other_member.email

      expect { described_class.sync_single('U123') }.not_to raise_error
      expect(SlackUser.find(identity.id)).to have_attributes(
        member_id: member.id,
        slack_email: member.email
      )
      expect(SlackUser.find(other_identity.id)).to have_attributes(
        member_id: other_member.id,
        slack_email: other_member.email,
        slack_id: 'UOTHER'
      )
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(event_type: 'slack_email_mismatch', resource_id: member.id)
      )
    end
  end

  describe '.sync_all' do
    let(:client) { double('Slack client') }

    def slack_member(id, email, real_name)
      {
        'id' => id,
        'is_bot' => false,
        'deleted' => false,
        'name' => real_name,
        'profile' => { 'email' => email, 'real_name' => real_name }
      }
    end

    before do
      SystemConfig.set(SystemConfig::SLACK_SYNC_ENABLED, 'true')
      allow(Service::SlackConnector).to receive(:api_token_present?).and_return(true)
      allow(Service::SlackConnector).to receive(:client).and_return(client)
      allow(Service::SlackConnector).to receive(:send_slack_message)
      allow(Service::SlackProfileSync).to receive(:sync_one)
      allow(Service::AuditLogger).to receive(:log)
      allow(Service::ErrorReporter).to receive(:notify)
      # create(:member) fires MemberSubscriber#send_slack_invite, which looks
      # up the member by email via this same client double — stub it to a
      # harmless "not found" so member creation in these examples doesn't
      # collide with the sync-specific users_list stubbing below.
      allow(client).to receive(:users_lookupByEmail).and_raise(Slack::Web::Api::Errors::UsersNotFound.new('not_found'))
    end

    it "reports and skips instead of raising when a member already has a different active Slack identity, and still processes users after it" do
      member = create(:member, email: 'shared@example.com')
      SlackUser.create!(member: member, slack_id: 'UACTIVE', slack_email: member.email)

      other_member = create(:member, email: 'other@example.com')

      allow(client).to receive(:users_list).and_return(
        'ok' => true,
        'members' => [
          slack_member('UDUPLICATE', member.email, 'Duplicate Identity'),
          slack_member('UNEXT', other_member.email, 'Next User')
        ],
        'response_metadata' => { 'next_cursor' => '' }
      )

      result = nil
      expect { result = described_class.sync_all }.not_to raise_error

      expect(result).to include(skipped: 1, created: 1)
      expect(SlackUser.where(slack_id: 'UDUPLICATE')).not_to exist
      expect(SlackUser.find_by(slack_id: 'UNEXT').member_id).to eq(other_member.id)
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(event_type: 'slack_identity_conflict', resource_id: member.id)
      )
    end

    it "continues processing subsequent users after an unexpected per-user error" do
      member = create(:member, email: 'first@example.com')
      other_member = create(:member, email: 'second@example.com')

      allow(client).to receive(:users_list).and_return(
        'ok' => true,
        'members' => [
          slack_member('UFAILS', member.email, 'Fails'),
          slack_member('USUCCEEDS', other_member.email, 'Succeeds')
        ],
        'response_metadata' => { 'next_cursor' => '' }
      )

      allow(described_class).to receive(:sanitized_slack_user_attributes).and_call_original
      allow(described_class).to receive(:sanitized_slack_user_attributes)
        .with(hash_including(slack_email: member.email))
        .and_raise(StandardError, 'boom')

      result = nil
      expect { result = described_class.sync_all }.not_to raise_error

      expect(result).to include(created: 1, failed: 1)
      expect(SlackUser.where(slack_id: 'UFAILS')).not_to exist
      expect(SlackUser.find_by(slack_id: 'USUCCEEDS').member_id).to eq(other_member.id)
      expect(Service::ErrorReporter).to have_received(:notify).with(
        instance_of(StandardError), context: hash_including(slack_id: 'UFAILS')
      )
    end
  end

  describe '.sanitized_slack_user_attributes' do
    it 'sanitizes Slack-sourced fields before atomic persistence' do
      attributes = described_class.sanitized_slack_user_attributes(
        slack_email: 'slack@example.com',
        name: 'Alice &lt;img src=x onerror=alert(1)&gt;',
        real_name: '<b>Real & R&D</b><script>alert(1)</script>'
      )

      expect(attributes).to eq(
        slack_email: 'slack@example.com',
        name: 'Alice ',
        real_name: 'Real & R&Dalert(1)'
      )
    end
  end
end
