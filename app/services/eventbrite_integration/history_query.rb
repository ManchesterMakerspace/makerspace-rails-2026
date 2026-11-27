module EventbriteIntegration
  class HistoryQuery
    class InvalidFilter < StandardError; end

    def initialize(scope, event_filter: {})
      @model = scope.klass
      @scope = scope
      @event_filter = event_filter
      @scope = scope.where(event_filter) if @model == EventbriteEvent
    end

    def self.event_filter(params)
      from, to = %i[from_date to_date].map do |key|
        value = params[key]
        next if value.nil? || value == ''
        unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
          raise InvalidFilter, "#{key} must be a valid YYYY-MM-DD date."
        end
        begin
          Date.iso8601(value)
        rescue Date::Error
          raise InvalidFilter, "#{key} must be a valid YYYY-MM-DD date."
        end
      end
      raise InvalidFilter, 'From must be on or before To.' if from && to && from > to

      bounds = {}
      bounds['$gte'] = from.in_time_zone('America/New_York').utc if from
      bounds['$lt'] = to.next_day.in_time_zone('America/New_York').utc if to
      filter = {}
      filter['starts_at'] = bounds if bounds.any?
      filter['name'] = { '$not' => /open house/i } if params[:exclude_open_house] == 'true'
      filter
    end

    def count
      return @scope.count if joins.empty?
      @model.collection.aggregate(filter_pipeline + [{ '$count' => 'count' }]).first&.fetch('count') || 0
    end

    def page(offset:, limit:)
      if joins.empty?
        return @scope.order_by(created_at: :desc, id: :desc).skip(offset).limit(limit).only(*Presenter::FIELDS)
      end
      pipeline = filter_pipeline + [{ '$sort' => { 'created_at' => -1, '_id' => -1 } },
        { '$skip' => offset }, { '$limit' => limit }, { '$project' => Presenter::FIELDS.index_with { 1 } }]
      @model.collection.aggregate(pipeline).map { |row| @model.instantiate(row) }
    end

    private

    def filter_pipeline = [{ '$match' => @scope.selector }] + joins

    def joins
      return [] if @model == EventbriteEvent || @event_filter.empty?

      # Keep orphan history visible when only excluding a title. A date
      # condition, on the other hand, requires a known parent start time.
      [{ '$lookup' => { 'from' => EventbriteEvent.collection_name.to_s,
        'localField' => 'event_id', 'foreignField' => 'eventbrite_id',
        'let' => { 'org' => '$organization_id' },
        'pipeline' => [{ '$match' => { '$expr' => { '$eq' => ['$organization_id', '$$org'] } } },
          { '$project' => { 'starts_at' => 1, 'name' => 1 } }],
        'as' => 'parent_event' } },
        { '$match' => @event_filter.transform_keys { |field| "parent_event.#{field}" } }]
    end
  end
end
