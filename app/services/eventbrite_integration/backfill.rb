module EventbriteIntegration
  class Backfill
    attr_reader :run
    class WaitingClient < Client
      def get(...)
        attempts = 0
        loop do
          begin
            return super
          rescue Deferred => e
            sleep([e.delay, 60].min)
          rescue Faraday::Error, Client::ApiError => e
            raise if e.is_a?(Client::ApiError) && e.status < 500
            attempts += 1
            raise if attempts >= 8
            sleep([2**attempts, 60].min)
          end
        end
      end
    end
    def initialize(kind, options = ENV)
      Configuration.validate!
      @kind, @options = kind, options
      @client = WaitingClient.new
      @sync = Synchronizer.new(@client)
    end
    def call
      @run = if @options['RESUME_RUN_ID'].present?
        EventbriteSyncRun.find(@options['RESUME_RUN_ID'])
      else
        EventbriteSyncRun.create!(kind: @kind, organizations: Configuration.organization_ids,
          filters: @options.to_h.slice('NAME_INCLUDE', 'NAME_EXCLUDE', 'CHANGED_SINCE'))
      end
      raise ArgumentError, 'Resume kind or organization configuration mismatch' unless @run.kind == @kind && (@run.organizations - Configuration.organization_ids).empty?
      return @run if @run.completed_at
      Lease.with("backfill:#{@run.id}") do |check|
        @run.organizations.each do |org|
          state = @run.progress[org] || {}
          next if state['done']
          if @kind == 'attendees' && !state.key?('since')
            since = @run.filters['CHANGED_SINCE']
            if since == 'last'
              prior = EventbriteSyncRun.where(kind: 'attendees', :completed_at.ne => nil, organizations: org).order_by(started_at: :desc).first
              since = prior ? (prior.started_at - 1).utc.iso8601 : nil
            end
            if since.present?
              parsed = Time.iso8601(since)
              raise ArgumentError, 'CHANGED_SINCE must be a UTC ISO8601 timestamp' unless parsed.utc_offset.zero?
              since = parsed.utc.iso8601
            end
            state['since'] = since
            checkpoint(org, state)
          end
          endpoint = @kind == 'attendees' ? "organizations/#{org}/attendees/" : "organizations/#{org}/events/"
          params = @kind == 'attendees' ? { 'changed_since' => state['since'] }.compact : { 'time_filter' => 'all', 'show_series_parent' => 'false' }
          restarted = false
          begin
            @client.each_page(endpoint, params, continuation: state['cursor']) do |body, cursor|
              body.fetch(@kind == 'attendees' ? 'attendees' : 'events').each do |data|
                check.call
                next if Array(state['completed_items']).include?(data.fetch('id').to_s)
                if @kind == 'attendees'
                  @sync.import_attendee(data)
                elsif matches?(data.dig('name', 'text'))
                  event = @sync.import_event(data)
                  if @kind == 'events'
                    @sync.tickets(event)
                  else
                    @client.each_page("events/#{event.eventbrite_id}/orders/", { 'status' => 'both', 'expand' => 'attendees,refund_requests' }, continuation: state['order_cursor']) do |orders, order_cursor|
                      orders.fetch('orders').each { |order| @sync.import_order(order); @run.inc(processed: 1) }
                      state['order_cursor'] = order_cursor
                      checkpoint(org, state)
                    end
                  end
                else
                  @run.inc(skipped: 1)
                  next
                end
                @run.inc(processed: 1) unless @kind == 'orders'
                state['completed_items'] = Array(state['completed_items']) + [data.fetch('id').to_s]
                checkpoint(org, state)
              end
              state['cursor'] = cursor
              state['completed_items'] = []
              state['done'] = cursor.nil?
              check.call
              checkpoint(org, state)
            end
          rescue Client::ApiError => e
            if e.code == 'BAD_CONTINUATION_TOKEN' && !restarted
              restarted = true
              state.merge!('cursor' => nil, 'order_cursor' => nil, 'completed_items' => [])
              checkpoint(org, state)
              retry
            end
            raise
          end
        end
        check.call
        @run.update!(completed_at: Time.current, last_error: nil, failed: 0)
      end
      @run
    rescue StandardError => e
      @run&.update!(last_error: e.is_a?(Client::ApiError) ? e.message : e.class.name, failed: 1)
      raise
    end
    private
    def checkpoint(org, state)
      @run.progress = @run.progress.merge(org => state.dup)
      @run.save!
    end
    def matches?(name)
      name = name.to_s.downcase
      included = @run.filters['NAME_INCLUDE'].to_s.downcase
      excluded = @run.filters['NAME_EXCLUDE'].to_s.downcase
      (included.empty? || name.include?(included)) && (excluded.empty? || !name.include?(excluded))
    end
  end
end
