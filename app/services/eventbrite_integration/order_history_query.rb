module EventbriteIntegration
  # Filter order history with an indexed existence join instead of shipping every
  # matching attendee/order pair to Ruby and back in an unbounded $or/$nor.
  class OrderHistoryQuery < HistoryQuery
    def initialize(scope, member_id: nil, linked: nil, event_filter: {})
      super(scope, event_filter: event_filter)
      @member_id, @linked = member_id, linked
    end

    def count
      return 0 if empty?
      super
    end

    def page(...)
      return [] if empty?
      super
    end

    private

    # Member history always intersects that member's linked attendees, including
    # when a later filter asks for orders with no linked attendees.
    def empty? = @member_id.present? && @linked == 'unlinked'

    def joins = super + relationship_pipeline

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
