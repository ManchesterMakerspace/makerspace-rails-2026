require 'rails_helper'

describe VolunteerEvent, type: :model do
  let(:organizer) { create(:member, :admin, status: 'activeMember') }
  let(:attendee)  { create(:member, status: 'activeMember') }

  before do
    allow(SlackUser).to receive(:find_by).and_return(nil)
    allow(Service::SlackConnector).to receive(:enque_message)
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(EarnedMembership).to receive_message_chain(:active, :where, :exists?).and_return(false)
    allow(Service::ErrorReporter).to receive(:notify)
  end

  describe '#close!' do
    it 'issues attendance credit to every attendee, including the organizer closing their own event' do
      event = VolunteerEvent.create!(
        title: 'January Cleanup',
        event_date: Date.today,
        created_by_id: organizer.id,
        attendee_ids: [organizer.id, attendee.id]
      )

      event.close!(organizer)

      expect(VolunteerCredit.where(member_id: organizer.id, issued_by_id: organizer.id, status: 'approved')).to exist
      expect(VolunteerCredit.where(member_id: attendee.id, issued_by_id: organizer.id, status: 'approved')).to exist
    end
  end
end
