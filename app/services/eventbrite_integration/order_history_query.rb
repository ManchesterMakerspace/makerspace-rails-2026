module EventbriteIntegration
  # Filter order history with an indexed existence join instead of shipping every
  # matching attendee/order pair to Ruby and back in an unbounded $or/$nor.
  class OrderHistoryQuery
    def initialize(scope, member_id: nil, linked: nil)
      @scope, @member_id, @linked = scope, member_id, linked
    end

    def count
      return 0 if empty?
      EventbriteOrder.collection.aggregate(filter_pipeline + [{ '$count' => 'count' }]).first&.fetch('count', 0) || 0
    end

    def page(offset:, limit:)
      return [] if empty?
      pipeline = filter_pipeline + [{ '$sort' => { 'created_at' => -1, '_id' => -1 } }, { '$skip' => offset }, { '$limit' => limit },
          { '$project' => Presenter::FIELDS.index_with { 1 }.merge('_id' => 1) }]
      EventbriteOrder.collection.aggregate(pipeline).map { |row| EventbriteOrder.instantiate(row) }
    end

    private

    # Member history always intersects that member's linked attendees, including
    # when a later filter asks for orders with no linked attendees.
    def empty? = @member_id.present? && @linked == 'unlinked'

    def filter_pipeline = [{ '$match' => @scope.selector }] + relationship_pipeline

    def relationship_pipeline
      conditions = {}
      conditions['member_id'] = @member_id if @member_id
      conditions['member_id'] = { '$ne' => nil } if !@member_id && @linked != 'conflict'
      conditions['link_conflict'] = true if @linked == 'conflict'
      conditions['$expr'] = { '$and' => [
        { '$eq' => ['$organization_id', '$$organization_id'] },
        { '$eq' => ['$order_id', '$$order_id'] }
      ] }
      [
        { '$lookup' => { 'from' => EventbriteAttendee.collection_name.to_s,
          'let' => { 'organization_id' => '$organization_id', 'order_id' => '$eventbrite_id' },
          'pipeline' => [{ '$match' => conditions }, { '$limit' => 1 }, { '$project' => { '_id' => 1 } }],
          'as' => 'matching_attendees' } },
        { '$match' => { 'matching_attendees.0' => { '$exists' => @linked != 'unlinked' } } }
      ]
    end
  end
end
