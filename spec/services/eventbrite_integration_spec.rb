require 'rails_helper'

RSpec.describe EventbriteIntegration::Synchronizer do
  let(:client) { instance_double(EventbriteIntegration::Client) }
  let(:sync) { described_class.new(client) }
  let(:event_data) { { 'id' => 'event-1', 'organization_id' => 'org-1', 'name' => { 'text' => 'Welding' }, 'listed' => true, 'status' => 'live', 'changed' => '2026-11-01T12:00:00Z', 'start' => { 'utc' => '2026-11-13T15:00:00Z', 'timezone' => 'America/New_York' } } }
  before do
    allow(Service::MemberProvisioning).to receive(:invite_slack)
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org-1'])
  end

  it 'upserts, ignores older event data, invalidates and republishes without losing history' do
    record = sync.import_event(event_data)
    sync.import_event(event_data.merge('status' => 'draft', 'changed' => '2026-11-02T12:00:00Z'))
    expect(record.reload.invalidated_at).to be_present
    sync.import_event(event_data)
    expect(record.reload.status).to eq('draft')
    sync.import_event(event_data.merge('changed' => '2026-11-03T12:00:00Z'))
    expect(record.reload.invalidated_at).to be_nil
    expect(EventbriteEvent.count).to eq(1)
  end

  it 'rejects other organizations' do
    expect { sync.import_event(event_data.merge('organization_id' => 'outside')) }.to raise_error(EventbriteIntegration::Client::ApiError)
    expect(EventbriteEvent.count).to eq(0)
  end

  it 'retains partial-refund invalidation after later placed updates' do
    sync.import_event(event_data)
    data = { 'id' => 'order-1', 'event_id' => 'event-1', 'status' => 'placed', 'refund_requests' => [{ 'items' => [{ 'status' => 'processed', 'item_type' => 'attendee' }] }] }
    order = sync.import_order(data)
    sync.import_order(data.except('refund_requests'))
    expect(order.reload.refunded_at).to be_present
    expect(order.invalidated_at).to be_present
    expect(order.refund_evidence).to include('processed_refund_request')
  end

  it 'links attendees, not buyers, and preserves links across email changes' do
    sync.import_event(event_data)
    first = create(:member)
    second = create(:member)
    order = { 'id' => 'order-1', 'event_id' => 'event-1', 'email' => second.email, 'attendees' => [
      { 'id' => 'attendee-1', 'profile' => { 'email' => " #{first.email.upcase} " } }
    ] }
    sync.import_order(order)
    attendee = EventbriteAttendee.first
    expect(attendee.member_id).to eq(first.id)
    order['attendees'][0]['profile']['email'] = second.email
    sync.import_order(order)
    expect(attendee.reload.member_id).to eq(first.id)
    expect(attendee.link_conflict).to be(true)
  end

  it 'links historical refunded attendees after signup' do
    attendee = EventbriteAttendee.create!(organization_id: 'org-1', eventbrite_id: 'past', email: 'new@example.com', refunded: true)
    member = create(:member, email: 'new@example.com')
    described_class # load before reconciling
    EventbriteIntegration::MemberLinker.reconcile(member)
    expect(attendee.reload.member_id).to eq(member.id)
    expect(attendee.refunded).to be(true)
    expect(member.reload.eventbrite_link_pending_at).to be_nil
  end

  it 'does not tombstone ticket classes on an incomplete listing' do
    parent = sync.import_event(event_data)
    ticket = EventbriteTicketClass.create!(organization_id: 'org-1', eventbrite_id: 'ticket-1', event_id: 'event-1')
    allow(client).to receive(:each_page).and_raise(EventbriteIntegration::Client::ApiError.new(500, 'ERROR'))
    expect { sync.tickets(parent) }.to raise_error(EventbriteIntegration::Client::ApiError)
    expect(ticket.reload.invalidated_at).to be_nil
  end
  it 'tombstones missing tickets only after a complete listing and the consistency delay' do
    sync.import_event(event_data)
    ticket = EventbriteTicketClass.create!(organization_id: 'org-1', eventbrite_id: 'ticket-1', event_id: 'event-1')
    resource = { 'type' => 'ticket_class', 'event_id' => 'event-1', 'id' => 'ticket-1' }
    expect { sync.refresh(resource, action: 'ticket_class.deleted', received_at: Time.current) }.to raise_error(EventbriteIntegration::Client::Deferred)
    allow(client).to receive(:each_page).and_yield({ 'ticket_classes' => [] }, nil)
    sync.refresh(resource, action: 'ticket_class.deleted', received_at: 301.seconds.ago)
    expect(ticket.reload.invalidation_reason).to eq('deleted')
  end
  it 'retries fresh 404 and publish state mismatches without invalidating known state' do
    record = sync.import_event(event_data)
    allow(client).to receive(:get).and_raise(EventbriteIntegration::Client::ApiError.new(404, 'NOT_FOUND'))
    expect { sync.refresh({ 'type' => 'event', 'id' => 'event-1' }, received_at: Time.current) }.to raise_error(EventbriteIntegration::Client::Deferred)
    expect(record.reload.invalidated_at).to be_nil
    allow(client).to receive(:get).and_return(event_data)
    expect { sync.refresh({ 'type' => 'event', 'id' => 'event-1' }, action: 'event.unpublished', received_at: Time.current) }.to raise_error(EventbriteIntegration::Client::Deferred)
  end
  it 'does not treat free orders as refunds and supports several attendees per order' do
    sync.import_event(event_data)
    members = 2.times.map { create(:member) }
    order = sync.import_order({ 'id' => 'order', 'event_id' => 'event-1', 'costs' => { 'gross' => { 'value' => 0 } }, 'attendees' => members.each_with_index.map { |member, i| { 'id' => "a#{i}", 'profile' => { 'email' => member.email } } } })
    expect(order.refunded_at).to be_nil
    expect(EventbriteAttendee.pluck(:member_id)).to match_array(members.map(&:id))
  end
  it 'never transfers historical links when a ghost email is reused' do
    old = create(:member, email: 'reuse@example.com')
    attendee = EventbriteAttendee.create!(organization_id: 'org-1', eventbrite_id: 'old', email: old.email, member_id: old.id)
    old.update_attribute(:merged_at, Time.current)
    returning = create(:member, email: old.email)
    EventbriteIntegration::MemberLinker.reconcile(returning)
    expect(attendee.reload.member_id).to eq(old.id)
    expect(attendee.link_conflict).to be(true)
    blank = EventbriteAttendee.create!(organization_id: 'org-1', eventbrite_id: 'blank')
    EventbriteIntegration::MemberLinker.link(blank)
    expect(blank.reload.member_id).to be_nil
  end
end
