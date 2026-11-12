require 'digest'

# Device requests arrive only through ts-data-api. The server resolves attendance
# from immutable session events; MQTT and caller-supplied member IDs are not evidence.
class ReaderReservationService
  class Conflict < StandardError; end
  class << self
    def sync!(body)
      raise ArgumentError, 'Object required' unless body.is_a?(Hash)
      device_id = bson_id(body['deviceId'])
      reader = collection('nfc_readers').find(_id: device_id, enabled: true).first
      raise ArgumentError, 'Reader unavailable' unless reader
      operations = body['operations']
      raise ArgumentError, 'At most 16 operations required' unless operations.is_a?(Array) && operations.size <= 16
      results = operations.map { |op| process(reader, op) }
      { results: results, serverTime: (Time.current.to_f * 1000).to_i }
    end

    def process(reader, op)
      raise ArgumentError, 'Invalid operation' unless op.is_a?(Hash) && %w[monitor claim release checkpoint].include?(op['kind'])
      id = bson_id(op['reservationId'])
      raise ArgumentError, 'Invalid revision' unless op['revision'].is_a?(Integer) && op['revision'] >= 0
      reservation = Reservation.where(id: id).first
      return { reservationId: id.to_s, outcome: 'gone' } unless reservation
      result = nil
      ReservationService.send(:with_shop_lock, reservation.shop_id) do
        reservation.reload
        monitor = reservation.reader_monitors[reader['_id'].to_s]
        current_tool = reader['role'] == 'tool' && reader['toolId']&.to_s
        old_tool = monitor && monitor['toolId']
        event = session_event(reader, op) if %w[claim release].include?(op['kind'])
        tool_id = event ? event['toolId'] : current_tool
        receipt_key = event && Digest::SHA256.hexdigest([reader['_id'], op['kind'], op['reservationId'], op['revision'], event['_id']].join(':'))
        fingerprint = Digest::SHA256.hexdigest(JSON.generate(op.sort.to_h))
        receipt = receipt_key && reservation.reader_receipts[receipt_key]
        if receipt
          raise Conflict, 'Conflicting duplicate operation' unless receipt['fingerprint'] == fingerprint
          deliver_syncs(reservation)
          result = receipt['result']
          next
        end
        if reservation.reader_revision != op['revision'] || reservation.status != 'approved'
          deliver_syncs(reservation)
          result = view(reservation, 'stale')
          next
        end
        # Stale work must be retired even after a resource move removed this
        # reader from the booking. Only current-revision mutations need scope.
        unless applies?(reservation, tool_id) && (tool_id == current_tool || tool_id == old_tool || (event && Array(reader['previousToolIds']).include?(tool_id)))
          raise ArgumentError, 'Reservation outside reader scope'
        end
        changes = {}
        case op['kind']
        when 'monitor'
          if reservation.reader_monitor_started_at.nil? && Time.current <= reservation.start_at + 15.minutes
            participants = participating_readers(reservation)
            if participants.any?
              changes[:reader_monitor_started_at] = Time.current
              changes[:reader_monitors] = participants
            end
          end
        when 'claim'
          observed = timestamp(op['observedAt'])
          raise ArgumentError, 'Attendance owner mismatch' unless event['memberId'] == reservation.member_id.to_s && event['validity'] == 'activeMember'
          unless observed >= reservation.start_at - 1.hour && observed <= reservation.start_at + 15.minutes && observed < reservation.end_at &&
              observed <= Time.current + 5.seconds && event['timeOf'] && event['timeOf'] <= observed
            raise ArgumentError, 'Attendance outside arrival window'
          end
          ended = collection('checkend').find(deviceId: reader['_id'], checkinId: event['_id'].to_s).first
          if ended && (!ended['timeOf'] || ended['timeOf'] < observed)
            raise ArgumentError, 'Session was not active at arrival'
          end
          if competing?(reservation, tool_id, observed)
            result = view(reservation, 'blocked')
            next
          end
          unless reservation.arrived_at
            changes.merge!(arrived_at: observed, arrival_reader_id: reader['_id'].to_s,
              arrival_tool_id: tool_id, arrival_checkin_id: event['_id'].to_s)
          end
        when 'release'
          start = collection('checkins').find(_id: bson_id(event['checkinId']), deviceId: reader['_id']).first
          unless start && start['memberId'] == reservation.member_id.to_s && start['toolId'] == event['toolId'] &&
              reservation.arrived_at && event['reason'] == 'logoff' && event['kicked'] == false && event['timeOf'] &&
              event['timeOf'] >= reservation.arrived_at && event['timeOf'] < reservation.end_at
            raise ArgumentError, 'Voluntary owner logoff required'
          end
          changes.merge!(status: 'cancelled', decision_note: 'released_on_logoff', decided_at: event['timeOf'],
            reader_revision: reservation.reader_revision + 1, calendar_sync_status: 'pending', reader_sync_pending: true)
        when 'checkpoint'
          from = timestamp(op['coveredFrom'])
          through = timestamp(op['through'])
          raise ArgumentError, 'Invalid coverage interval' unless from <= through && through <= Time.current + 5.seconds
          monitors = reservation.reader_monitors.deep_dup
          entry = monitors[reader['_id'].to_s]
          if entry && reader['reservationEnabled'] == true && current_tool == entry['toolId'] &&
              entry['coverageRevision'].to_i == reader['reservationCoverageRevision'].to_i
            entry['from'] = op['uncertain'] == true ? nil : from
            entry['through'] = op['uncertain'] == true ? nil : through
            changes[:reader_monitors] = monitors
            attendance = recorded_attendance(reservation, monitors) unless reservation.arrived_at
            if attendance.is_a?(Hash)
              changes.merge!(attendance) # Positive evidence never waits for other offline participants.
            elsif attendance != :uncertain && abandonable?(reservation, monitors)
              changes.merge!(status: 'abandoned', abandoned_at: Time.current,
                abandonment_reason: 'no_checkin_within_15_minutes', reader_revision: reservation.reader_revision + 1,
                calendar_sync_status: 'pending', reader_sync_pending: true)
            end
          end
        end
        if receipt_key
          raise Conflict, 'Attendance receipt capacity exceeded' if reservation.reader_receipts.size >= 256
          receipts = reservation.reader_receipts.deep_dup
          receipts[receipt_key] = { 'fingerprint' => fingerprint, 'result' => {
            reservationId: reservation.id.to_s, outcome: 'accepted', status: changes[:status] || reservation.status,
            revision: changes[:reader_revision] || reservation.reader_revision } }
          changes[:reader_receipts] = receipts
        end
        commit(reservation, changes) if changes.any?
        deliver_syncs(reservation)
        result = view(reservation, 'accepted')
      end
      result
    end

    private

    def collection(name) = Mongoid.default_client[name]
    def bson_id(value)
      raise ArgumentError, 'Invalid identifier' unless value.to_s.match?(/\A[0-9a-f]{24}\z/)
      BSON::ObjectId.from_string(value.to_s)
    end
    def timestamp(value)
      raise ArgumentError, 'Invalid timestamp' unless value.is_a?(Integer) && value >= 1_700_000_000_000 && value < 8_640_000_000_000_000
      Time.at(Rational(value, 1000)).utc
    end
    def view(r, outcome)
      { reservationId: r.id.to_s, outcome: outcome, status: r.status, revision: r.reader_revision,
        monitored: r.reader_monitor_started_at.present?, arrivedAt: r.arrived_at && (r.arrived_at.to_r * 1000).to_i }
    end
    def session_event(reader, op)
      field = op['kind'] == 'claim' ? 'checkinId' : 'checkendId'
      name = op['kind'] == 'claim' ? 'checkins' : 'checkend'
      event = collection(name).find(_id: bson_id(op[field]), deviceId: reader['_id']).first
      raise Conflict, 'Session event not synchronized yet' unless event
      event
    end
    def applies?(r, tool_id)
      return false unless tool_id.to_s.match?(/\A[0-9a-f]{24}\z/)
      return r.tool_ids.include?(tool_id) if r.reservation_scope == 'tools'
      Tool.where(id: tool_id, shop_id: r.shop_id).exists?
    end
    def participating_readers(r)
      ids = r.reservation_scope == 'shop' ? Tool.where(shop_id: r.shop_id).pluck(:id) : r.tool_ids.map { |id| bson_id(id) }
      collection('nfc_readers').find(enabled: true, role: 'tool', reservationEnabled: true, :toolId => { '$in' => ids }).to_h do |reader|
        [reader['_id'].to_s, { 'toolId' => reader['toolId'].to_s, 'coverageRevision' => reader['reservationCoverageRevision'].to_i }]
      end
    end
    def competing?(r, tool_id, observed)
      active = Reservation.where(:id.ne => r.id, status: 'approved', shop_id: r.shop_id,
        :start_at.lte => observed, :end_at.gt => observed).any_of(
          { reservation_scope: 'shop' }, { tool_ids: tool_id }).exists?
      active || earlier_pending(r, tool_id, observed).any?
    end
    def earlier_pending(r, tool_id, observed)
      return [] if observed >= r.start_at
      Reservation.where(:id.ne => r.id, status: 'approved', shop_id: r.shop_id,
        :start_at.gt => observed, :start_at.lte => r.start_at).any_of(
          { reservation_scope: 'shop' }, { tool_ids: tool_id }).select do |other|
        other.start_at < r.start_at || other.id.to_s < r.id.to_s
      end
    end
    def abandonable?(r, monitors)
      cutoff = r.start_at + 15.minutes
      return false if r.arrived_at || !r.reader_monitor_started_at || r.reader_monitor_started_at > cutoff ||
        Time.current <= cutoff || monitors.empty?
      required_from = [r.reader_monitor_started_at, r.start_at - 1.hour].max
      monitors.all? do |id, checkpoint|
        reader = collection('nfc_readers').find(_id: bson_id(id), enabled: true, role: 'tool', reservationEnabled: true).first
        reader && reader['toolId'].to_s == checkpoint['toolId'] && reader['reservationCoverageRevision'].to_i == checkpoint['coverageRevision'].to_i && checkpoint['from'] && checkpoint['through'] &&
          checkpoint['from'] <= required_from && checkpoint['through'] > cutoff
      end
    end
    def recorded_attendance(r, monitors)
      first = r.start_at - 1.hour
      cutoff = r.start_at + 15.minutes
      unknown = false
      # A reader can have missed the booking while offline. Its normal immutable
      # checkins are still evidence even when it could not queue a reservation claim.
      monitors.each do |id, checkpoint|
        device = bson_id(id)
        candidates = collection('checkins').find(deviceId: device, memberId: r.member_id.to_s,
          validity: 'activeMember', timeOf: { '$gte' => first, '$lte' => cutoff }).sort(timeOf: 1).to_a
        carried = collection('checkins').find(deviceId: device, validity: 'activeMember',
          timeOf: { '$lt' => first, '$ne' => nil }).sort(timeOf: -1).limit(1).first
        candidates.unshift(carried) if carried && carried['memberId'] == r.member_id.to_s
        candidates.each do |event|
          next unless event['toolId'] == checkpoint['toolId'] && applies?(r, event['toolId'])
          observed = [event['timeOf'], first, r.created_at, r.reader_scope_changed_at].compact.max
          ending = collection('checkend').find(deviceId: device, checkinId: event['_id'].to_s).first
          if event['timeOf'] < observed && ending && !ending['timeOf']
            unknown = true
            next
          end
          # While a previous booking runs, an already-running owner waits until
          # it ends; this reproduces the firmware's automatic association rule.
          loop do
            blockers = Reservation.where(:id.ne => r.id, status: 'approved', shop_id: r.shop_id,
              :start_at.lte => observed, :end_at.gt => observed).any_of(
                { reservation_scope: 'shop' }, { tool_ids: event['toolId'] }).to_a
            blockers.concat(earlier_pending(r, event['toolId'], observed))
            break if blockers.empty?
            observed = blockers.map(&:end_at).max
            break if observed > cutoff
          end
          next if observed > cutoff || observed >= r.end_at || (ending && ending['timeOf'] && ending['timeOf'] < observed)
          result = { arrived_at: observed, arrival_reader_id: id, arrival_tool_id: event['toolId'], arrival_checkin_id: event['_id'].to_s }
          if ending && ending['reason'] == 'logoff' && ending['kicked'] == false && ending['timeOf'] && ending['timeOf'] < r.end_at
            result.merge!(status: 'cancelled', decision_note: 'released_on_logoff', decided_at: ending['timeOf'],
              reader_revision: r.reader_revision + 1, calendar_sync_status: 'pending', reader_sync_pending: true)
          end
          return result
        end
      end
      unknown ? :uncertain : nil
    end
    def commit(r, changes)
      # Match absent legacy revisions as zero, and fence concurrent checkpoints.
      filter = { '_id' => r.id, 'status' => 'approved', '$and' => %w[reader_revision reader_state_version].map { |key|
        value = r.public_send(key).to_i
        value.zero? ? { '$or' => [{ key => 0 }, { key => { '$exists' => false } }] } : { key => value }
      } }
      updated = Reservation.collection.find(filter).find_one_and_update(
        { '$set' => changes.merge(updated_at: Time.current), '$inc' => { reader_state_version: 1 } }, return_document: :after)
      raise Conflict, 'Reservation changed; refresh required' unless updated
      r.reload
    end
    def deliver_syncs(r)
      return unless r.reader_sync_pending
      ReservationService.send(:enqueue_external_syncs, r)
      r.set(reader_sync_pending: false)
    end
  end
end
