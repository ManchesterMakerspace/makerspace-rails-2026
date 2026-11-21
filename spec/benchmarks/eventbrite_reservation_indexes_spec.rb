require 'rails_helper'

# Opt-in probes on disposable data; never use these examples on a valued database.
RSpec.describe 'Eventbrite and reservation read index plans', :benchmark do
  def explain(command)
    Mongoid.default_client.database.command(explain: command, verbosity: 'executionStats').first
  end

  def index_names(value)
    case value
    when Hash
      value.flat_map { |key, child| %w[indexName indexesUsed].include?(key.to_s) ? Array(child) : index_names(child) }
    when Array
      value.flat_map { |child| index_names(child) }
    else
      []
    end
  end

  def report(name, result)
    stats = result['executionStats'] || result.dig('stages', 0, '$cursor', 'executionStats') || {}
    lookups = Array(result['stages']).select { |stage| stage.key?('$lookup') }
    puts "QUERY_INDEX_BENCHMARK #{JSON.generate(operation: name,
      returned: stats['nReturned'], examined_documents: stats['totalDocsExamined'],
      examined_keys: stats['totalKeysExamined'], indexes: index_names(result).uniq,
      lookup_examined_documents: lookups.sum { |stage| stage.fetch('totalDocsExamined', 0) },
      lookup_examined_keys: lookups.sum { |stage| stage.fetch('totalKeysExamined', 0) },
      lookup_collection_scans: lookups.sum { |stage| stage.fetch('collectionScans', 0) })}"
  end

  it 'bounds a global day lookup despite a large approved reservation history' do
    today = Time.utc(2026, 11, 20, 5)
    Reservation.collection.insert_many(Array.new(10_000) do |number|
      start_at = today - (number % 365 + 1).days
      { status: 'approved', start_at: start_at, end_at: start_at + 1.hour }
    end + Array.new(10) { { status: 'approved', start_at: today + 10.hours, end_at: today + 11.hours } })
    command = { find: Reservation.collection_name.to_s,
      filter: Reservation.blocking.where(:end_at.gt => today, :start_at.lt => today + 1.day).selector,
      projection: { _id: 1, start_at: 1, end_at: 1 }, sort: { start_at: 1, _id: 1 } }
    # Existing shop/member/tool-leading indexes cannot bound this global query.
    before = explain(command.merge(hint: { '$natural' => 1 }))
    Reservation.collection.indexes.create_one(status: 1, end_at: 1, start_at: 1)
    after = explain(command)
    report('reservation_scan', before)
    report('reservation_indexed', after)
    expect(after.dig('executionStats', 'nReturned')).to eq(10)
    expect(after.dig('executionStats', 'totalDocsExamined')).to be < before.dig('executionStats', 'totalDocsExamined')
    expect(index_names(after)).to include('status_1_end_at_1_start_at_1')
  end

  it 'uses the organization/order/member index inside attendee existence joins' do
    key = { organization_id: 1, order_id: 1, member_id: 1 }
    name = key.map { |field, direction| "#{field}_#{direction}" }.join('_')
    EventbriteAttendee.index_specifications.each do |index|
      next if index.key.stringify_keys.to_a == key.stringify_keys.to_a
      EventbriteAttendee.collection.indexes.create_one(index.key, index.options)
    end
    if EventbriteAttendee.collection.indexes.to_a.any? { |index| index['name'] == name }
      EventbriteAttendee.collection.indexes.drop_one(name)
    end
    member_id = BSON::ObjectId.new
    EventbriteOrder.collection.insert_many(Array.new(100) { |number| { organization_id: 'probe', eventbrite_id: number.to_s } })
    EventbriteAttendee.collection.insert_many(Array.new(5000) do |number|
      { organization_id: 'probe', eventbrite_id: number.to_s, event_id: (number % 20).to_s,
        order_id: (number % 100).to_s, member_id: member_id }
    end)
    query = EventbriteIntegration::OrderHistoryQuery.new(EventbriteOrder.where(organization_id: 'probe'), linked: 'linked')
    command = { aggregate: EventbriteOrder.collection_name.to_s,
      pipeline: query.send(:filter_pipeline) + [{ '$count' => 'count' }], cursor: {} }
    before = explain(command)
    EventbriteAttendee.collection.indexes.create_one(key)
    after = explain(command)
    report('attendee_existing_indexes', before)
    report('attendee_order_index', after)
    expect(index_names(after)).to include(name)
    expect(Array(after['stages']).select { |stage| stage.key?('$lookup') }.sum { |stage| stage.fetch('collectionScans', 0) }).to eq(0)
  ensure
    EventbriteAttendee.collection.indexes.create_one(key) if key
  end
end
