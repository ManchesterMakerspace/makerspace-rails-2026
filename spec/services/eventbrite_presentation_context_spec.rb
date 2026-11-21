require 'rails_helper'

RSpec.describe EventbriteIntegration::PresentationContext do
  include ReservationReadMeasurement

  it 'keeps cold relationship query counts bounded for one or fifty mixed rows' do
    EventbriteEvent.create!(organization_id: 'org', eventbrite_id: 'event', name: 'Workshop',
      starts_at: Time.utc(2026, 11, 1, 12, 0, 0, 123000), timezone: 'America/New_York')
    EventbriteTicketClass.create!(organization_id: 'org', eventbrite_id: 'ticket', name: 'Admission')
    records = 25.times.flat_map do |i|
      order = EventbriteOrder.create!(organization_id: 'org', eventbrite_id: "order-#{i}", event_id: 'event')
      attendee = EventbriteAttendee.create!(organization_id: 'org', eventbrite_id: "attendee-#{i}",
        event_id: 'event', order_id: order.eventbrite_id, ticket_class_id: 'ticket', member_id: BSON::ObjectId.new)
      [order, attendee]
    end
    one = records.first
    EventbriteIntegration::DisplayCache.invalidate_all
    single = measure_reservation_reads { EventbriteIntegration::Presenter.many([one]) }
    EventbriteIntegration::DisplayCache.invalidate_all
    many = measure_reservation_reads { EventbriteIntegration::Presenter.many(records) }
    expect(single[:commands].size).to be <= 3
    expect(many[:commands].size).to be <= 3
    expect(many[:result].size).to eq(50)
    expect(many[:commands].none? { |command, _| command == 'distinct' }).to be(true)
    warm = measure_reservation_reads { EventbriteIntegration::Presenter.many(records) }
    expect(warm[:commands].size).to eq(1)
    expect(JSON.parse(warm[:result].to_json)).to eq(JSON.parse(many[:result].to_json))
  end

  it 'batches relationships and keeps identical provider IDs in different organizations separate' do
    member_id = BSON::ObjectId.new
    records = %w[first second].flat_map do |org|
      EventbriteEvent.create!(organization_id: org, eventbrite_id: 'event', name: "#{org} event", starts_at: Time.utc(2026, 11, 1), timezone: 'America/New_York')
      EventbriteTicketClass.create!(organization_id: org, eventbrite_id: 'ticket', event_id: 'event', name: "#{org} ticket")
      order = EventbriteOrder.create!(organization_id: org, eventbrite_id: 'order', event_id: 'event')
      attendee = EventbriteAttendee.create!(organization_id: org, eventbrite_id: 'attendee', event_id: 'event', order_id: 'order', ticket_class_id: 'ticket', member_id: member_id)
      EventbriteAttendee.create!(organization_id: org, eventbrite_id: 'duplicate-link', order_id: 'order', member_id: member_id)
      [order, attendee]
    end
    measured = measure_reservation_reads { EventbriteIntegration::Presenter.many(records) }
    expect(measured[:commands].count { |_, collection| collection == 'eventbrite_events' }).to eq(1)
    expect(measured[:commands].count { |_, collection| collection == 'eventbrite_ticket_classes' }).to eq(1)
    expect(measured[:commands].count { |_, collection| collection == 'eventbrite_attendees' }).to eq(1)
    first_order, first_attendee, second_order, second_attendee = measured[:result]
    expect(first_order['memberIds']).to eq([member_id.to_s])
    expect(second_order['memberIds']).to eq([member_id.to_s])
    expect(first_attendee['event'][:name]).to eq('first event')
    expect(second_attendee['event'][:name]).to eq('second event')
    expect(first_attendee['ticketClassName']).to eq('first ticket')
    expect(second_attendee['ticketClassName']).to eq('second ticket')
  end

  it 'omits missing relationships and retains an empty member ID list' do
    order = EventbriteOrder.create!(organization_id: 'org', eventbrite_id: 'order', event_id: 'missing')
    attendee = EventbriteAttendee.create!(organization_id: 'org', eventbrite_id: 'attendee', event_id: 'missing', ticket_class_id: 'missing')
    results = EventbriteIntegration::Presenter.many([order, attendee])
    expect(results[0]['memberIds']).to eq([])
    expect(results.all? { |row| !row.key?('event') }).to be(true)
    expect(results[1]).not_to have_key('ticketClassName')
  end

  it 'reads current member links even when shared event metadata is warm' do
    EventbriteEvent.create!(organization_id: 'org', eventbrite_id: 'event', name: 'Workshop')
    order = EventbriteOrder.create!(organization_id: 'org', eventbrite_id: 'order', event_id: 'event')
    attendee = EventbriteAttendee.create!(organization_id: 'org', eventbrite_id: 'attendee', order_id: 'order')
    expect(EventbriteIntegration::Presenter.call(order)['memberIds']).to eq([])
    member_id = BSON::ObjectId.new
    attendee.set(member_id: member_id)
    measured = measure_reservation_reads { EventbriteIntegration::Presenter.call(order) }
    expect(measured[:result]['memberIds']).to eq([member_id.to_s])
    expect(measured[:commands].none? { |_, collection| collection == 'eventbrite_events' }).to be(true)
  end
end
