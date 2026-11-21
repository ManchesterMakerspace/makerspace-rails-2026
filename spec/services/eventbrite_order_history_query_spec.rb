require 'rails_helper'

RSpec.describe EventbriteIntegration::OrderHistoryQuery do
  let(:member_id) { BSON::ObjectId.new }

  def order(org, id, **attributes)
    EventbriteOrder.create!({ organization_id: org, eventbrite_id: id }.merge(attributes))
  end

  def attendee(org, order_id, **attributes)
    EventbriteAttendee.create!({ organization_id: org, eventbrite_id: SecureRandom.uuid, order_id: order_id }.merge(attributes))
  end

  def query(**filters)
    described_class.new(EventbriteOrder.all, **filters)
  end

  it 'joins by organization and order ID and deduplicates several matching attendees' do
    own = order('org', 'same')
    order('other', 'same')
    2.times { attendee('org', 'same', member_id: member_id) }
    history = query(member_id: member_id)
    expect(history.count).to eq(1)
    expect(history.page(offset: 0, limit: 50).map(&:id)).to eq([own.id])
  end

  it 'filters before pagination, keeps the total and sorts ties by descending ID' do
    now = Time.current
    matching = 3.times.map do |i|
      record = order('org', "match-#{i}", created_at: now)
      attendee('org', record.eventbrite_id, member_id: member_id)
      record
    end
    order('org', 'newer-unlinked', created_at: now + 1.hour)
    history = query(linked: 'linked')
    expect(history.count).to eq(3)
    expect(history.page(offset: 1, limit: 1).map(&:id)).to eq([matching[1].id])
    expect(history.page(offset: 10, limit: 1)).to eq([])
    expect(history.count).to eq(3)
  end

  it 'includes orders with no attendees or only unlinked attendees in global unlinked history' do
    empty = order('org', 'empty')
    unlinked = order('org', 'unlinked')
    linked = order('org', 'linked')
    attendee('org', unlinked.eventbrite_id)
    attendee('org', linked.eventbrite_id, member_id: member_id)
    history = query(linked: 'unlinked')
    expect(history.count).to eq(2)
    expect(history.page(offset: 0, limit: 50).map(&:id)).to match_array([empty.id, unlinked.id])
    expect(query(member_id: member_id, linked: 'unlinked').count).to eq(0)
  end

  it 'intersects conflict filtering with the selected member and current order scope' do
    own = order('org', 'own', status: 'placed')
    order('org', 'other', status: 'placed')
    order('org', 'refunded', status: 'refunded')
    attendee('org', 'own', member_id: member_id, link_conflict: true)
    attendee('org', 'other', member_id: BSON::ObjectId.new, link_conflict: true)
    attendee('org', 'refunded', member_id: member_id, link_conflict: true)
    history = described_class.new(EventbriteOrder.where(status: 'placed'), member_id: member_id, linked: 'conflict')
    expect(history.count).to eq(1)
    expect(history.page(offset: 0, limit: 50).map(&:id)).to eq([own.id])
  end
end
