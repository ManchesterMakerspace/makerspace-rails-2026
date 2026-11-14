require 'rails_helper'
RSpec.describe EventbriteEvent do
  before { allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org']) }
  before { allow(Service::MemberProvisioning).to receive(:invite_slack) }
  def event(id, **attributes)
    EventbriteEvent.create!({ organization_id: 'org', eventbrite_id: id, name: 'Workshop', starts_at: Time.current,
      timezone: 'America/New_York', status: 'ended', listed: true }.merge(attributes))
  end
  it 'offers only public eligible event names and includes both calendar boundaries' do
    travel_to Time.utc(2026, 11, 13, 12) do
      valid = event('1', starts_at: Time.utc(2026, 9, 13, 4))
      event('2', name: 'Monthly OPEN HOUSE')
      event('3', listed: false)
      event('4', starts_at: Time.utc(2026, 9, 13, 3, 59))
      last = event('5', starts_at: Time.utc(2026, 12, 14, 4, 59))
      event('6', starts_at: Time.utc(2026, 12, 14, 5))
      EventbriteTicketClass.create!(organization_id: 'org', eventbrite_id: 't', event_id: valid.eventbrite_id, name: 'Open House')
      expect(described_class.signup_choices.pluck(:id)).to eq([valid.id, last.id])
    end
  end
  it 'captures an event snapshot and preserves it after the event ages out' do
    source = event('1')
    member = create(:member, signup_source: 'eventbrite', signup_eventbrite_event_id: source.id)
    source.update!(name: 'Renamed', invalidated_at: Time.current)
    member.update!(firstname: 'Changed')
    expect(member.signup_eventbrite_event_snapshot['name']).to eq('Workshop')
    expect(build(:member, signup_source: 'eventbrite', signup_eventbrite_event_id: source.id)).not_to be_valid
  end
end
