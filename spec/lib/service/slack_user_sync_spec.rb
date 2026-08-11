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
