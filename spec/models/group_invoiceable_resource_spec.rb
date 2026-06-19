require 'rails_helper'

RSpec.describe Group, type: :model do
  describe 'invoiceable resource support' do
    let(:member) { create(:member) }
    let(:group) { create(:group, member: member, groupRep: member.fullname, groupName: member.id.to_s) }

    it 'supports renewal slack notification callbacks used by invoice settlement' do
      allow(SlackUser).to receive(:find_by).with(member_id: member.id).and_return(nil)
      allow(Service::SlackConnector).to receive(:send_slack_message)

      expect { group.send_renewal_slack_message }.not_to raise_error
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        group.get_renewal_slack_message(nil),
        Service::SlackConnector.members_relations_channel
      )
    end

    it 'supports renewal reversal slack notification callbacks used by invoice reversal' do
      allow(SlackUser).to receive(:find_by).with(member_id: member.id).and_return(nil)
      allow(Service::SlackConnector).to receive(:send_slack_message)

      expect { group.send_renewal_reversal_slack_message }.not_to raise_error
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        group.get_renewal_reversal_slack_message,
        Service::SlackConnector.members_relations_channel
      )
    end

    it 'stores and removes subscription metadata used by household invoices' do
      group.update!(subscription_id: 'household_subscription', subscription: true)

      expect { group.remove_subscription }.to change { group.reload.subscription_id }.to(nil)
      expect(group.subscription).to be(false)
    end
  end
end
