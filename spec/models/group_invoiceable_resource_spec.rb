require 'rails_helper'

RSpec.describe Group, type: :model do
  describe 'invoiceable resource support' do
    let(:member) { create(:member) }
    let(:group) { create(:group, member: member, groupRep: member.fullname, groupName: member.id.to_s) }

    describe '#send_renewal_slack_message' do
      it 'queues both the member DM and management channel notification under distinct keys' do
        slack_user = SlackUser.create!(member_id: member.id, slack_id: "U_TEST_GROUP_MEMBER")

        group.send_renewal_slack_message

        enqueued = Service::SlackConnector.get_enqueued_messages("#{Current.request_id}.*")
        channels = enqueued.values.map { |payload| JSON.parse(payload)["channel"] }

        expect(channels).to include(slack_user.slack_id)
        expect(channels).to include(Service::SlackConnector.members_relations_channel)
        expect(channels.size).to eq(2)
      end

      it 'queues only the management channel notification when the primary member has no SlackUser' do
        group.send_renewal_slack_message

        enqueued = Service::SlackConnector.get_enqueued_messages("#{Current.request_id}.*")
        channels = enqueued.values.map { |payload| JSON.parse(payload)["channel"] }

        expect(channels).to eq([Service::SlackConnector.members_relations_channel])
      end
    end

    describe '#send_renewal_reversal_slack_message' do
      it 'queues both the member DM and management channel notification under distinct keys' do
        slack_user = SlackUser.create!(member_id: member.id, slack_id: "U_TEST_GROUP_MEMBER")

        group.send_renewal_reversal_slack_message

        enqueued = Service::SlackConnector.get_enqueued_messages("#{Current.request_id}.*")
        channels = enqueued.values.map { |payload| JSON.parse(payload)["channel"] }

        expect(channels).to include(slack_user.slack_id)
        expect(channels).to include(Service::SlackConnector.members_relations_channel)
        expect(channels.size).to eq(2)
      end
    end

    it 'stores and removes subscription metadata used by household invoices' do
      group.update!(subscription_id: 'household_subscription', subscription: true)
      expect { group.remove_subscription }.to change { group.reload.subscription_id }.to(nil)
      expect(group.subscription).to be(false)
    end
  end
end
