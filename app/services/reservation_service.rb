class ReservationService
  ZONE = ActiveSupport::TimeZone["America/New_York"].freeze
  LOCK_TTL_SECONDS = 15

  class << self
    def preview(member:, attributes:, reservation: nil)
      normalized = normalize(attributes, reservation)
      if reservation && !material_edit?(reservation, normalized)
        errors = normalized[:title].blank? ? ["Title is required"] : []
        reasons = Array(reservation.approval_reasons)
        return {
          eligible: errors.empty?,
          errors: errors,
          conflicts: [],
          missingPrerequisites: [],
          requiresApproval: reservation.status == "pending",
          approvalReasons: reasons
        }
      end

      evaluation = evaluate(member: member, attributes: normalized, reservation: reservation)
      {
        eligible: evaluation[:errors].empty? && evaluation[:conflicts].empty?,
        errors: evaluation[:errors],
        conflicts: evaluation[:conflicts],
        missingPrerequisites: evaluation[:missing_prerequisites],
        requiresApproval: evaluation[:approval_reasons].present?,
        approvalReasons: evaluation[:approval_reasons]
      }
    end

    def create!(member:, attributes:, source: "portal")
      normalized = normalize(attributes)
      with_shop_lock(normalized[:shop_id]) do
        evaluation = evaluate(member: member, attributes: normalized)
        raise_for_evaluation!(evaluation)

        reservation = Reservation.create!(
          normalized.merge(
            member_id: member.id,
            status: evaluation[:approval_reasons].present? ? "pending" : "approved",
            approval_reasons: evaluation[:approval_reasons],
            source: source,
            calendar_sync_status: "pending"
          )
        )
        enqueue_calendar_sync(reservation)
        reservation
      end
    end

    def update!(reservation:, attributes:)
      unless reservation.blocking? && reservation.end_at > Time.current
        raise ::Error::UnprocessableEntity.new("Only future active reservations can be changed")
      end

      normalized = normalize(attributes, reservation)
      with_shop_locks([reservation.shop_id, normalized[:shop_id]]) do
        unless material_edit?(reservation, normalized)
          reservation.update!(
            title: normalized[:title],
            calendar_sync_status: "pending",
            calendar_sync_error: nil
          )
          enqueue_calendar_sync(reservation)
          next reservation
        end

        evaluation = evaluate(member: reservation.member, attributes: normalized, reservation: reservation)
        raise_for_evaluation!(evaluation)

        reservation.update!(
          normalized.merge(
            status: evaluation[:approval_reasons].present? ? "pending" : "approved",
            approval_reasons: evaluation[:approval_reasons],
            decided_by_id: nil,
            decided_at: nil,
            decision_note: nil,
            calendar_sync_status: "pending",
            calendar_sync_error: nil
          )
        )
        enqueue_calendar_sync(reservation)
        reservation
      end
    end

    def cancel!(reservation:, actor:)
      unless reservation.blocking? && reservation.end_at > Time.current
        raise ::Error::UnprocessableEntity.new("Only future active reservations can be canceled")
      end

      with_shop_lock(reservation.shop_id) do
        reservation.update!(
          status: "canceled",
          decided_by_id: actor.id,
          decided_at: Time.current,
          calendar_sync_status: "pending",
          calendar_sync_error: nil
        )
        enqueue_calendar_sync(reservation)
        reservation
      end
    end

    def approve!(reservation:, actor:, note: nil)
      raise ::Error::UnprocessableEntity.new("Only pending reservations can be approved") unless reservation.status == "pending"
      raise ::Error::Forbidden.new("You cannot approve your own reservation") if reservation.member_id.to_s == actor.id.to_s

      reservation.update!(
        status: "approved",
        decision_note: note,
        decided_by_id: actor.id,
        decided_at: Time.current,
        calendar_sync_status: "pending",
        calendar_sync_error: nil
      )
      enqueue_calendar_sync(reservation)
      reservation
    end

    def deny!(reservation:, actor:, note: nil)
      raise ::Error::UnprocessableEntity.new("Only pending reservations can be denied") unless reservation.status == "pending"

      reservation.update!(
        status: "denied",
        decision_note: note,
        decided_by_id: actor.id,
        decided_at: Time.current,
        calendar_sync_status: "pending",
        calendar_sync_error: nil
      )
      enqueue_calendar_sync(reservation)
      reservation
    end

    private

    def normalize(attributes, reservation = nil)
      source = attributes.to_h.symbolize_keys
      {
        title: source[:title].presence || reservation&.title,
        shop_id: source[:shop_id].presence || reservation&.shop_id,
        reservation_scope: source[:reservation_scope].presence || reservation&.reservation_scope,
        tool_ids: source.key?(:tool_ids) ? Array(source[:tool_ids]).map(&:to_s).uniq : Array(reservation&.tool_ids).map(&:to_s),
        start_at: parse_time(source[:start_at].presence || reservation&.start_at),
        end_at: parse_time(source[:end_at].presence || reservation&.end_at)
      }
    end

    def parse_time(value)
      return value.utc if value.respond_to?(:utc)
      Time.iso8601(value.to_s).utc
    rescue ArgumentError
      nil
    end

    def evaluate(member:, attributes:, reservation: nil)
      errors = []
      conflicts = []
      missing = []
      approval_reasons = []

      shop = Shop.where(id: attributes[:shop_id]).first
      unless shop
        return {
          errors: ["Selected shop was not found"],
          conflicts: [],
          missing_prerequisites: [],
          approval_reasons: []
        }
      end
      tools = attributes[:reservation_scope] == "tools" ?
        Tool.where(shop_id: shop.id, :id.in => attributes[:tool_ids]).to_a : []
      resources = attributes[:reservation_scope] == "shop" ? [shop] : tools

      errors << "Title is required" if attributes[:title].blank?
      errors << "Membership must be active and unexpired" unless member.active_unexpired?
      errors << "Start and end times are required" if attributes[:start_at].blank? || attributes[:end_at].blank?
      errors << "Start time must be in the future" if attributes[:start_at].present? && attributes[:start_at] < Time.current
      errors << "End time must be after start time" if attributes[:start_at].present? && attributes[:end_at].present? && attributes[:end_at] <= attributes[:start_at]
      errors << "Times must use 30-minute increments" unless half_hour?(attributes[:start_at]) && half_hour?(attributes[:end_at])
      errors << "Reservation scope must be shop or tools" unless Reservation::SCOPES.include?(attributes[:reservation_scope])
      errors << "Select at least one tool" if attributes[:reservation_scope] == "tools" && attributes[:tool_ids].empty?
      errors << "One or more selected tools are invalid" if attributes[:reservation_scope] == "tools" && tools.length != attributes[:tool_ids].length
      errors << "The selected shop is not reservable" if attributes[:reservation_scope] == "shop" && (!shop.reservable || shop.disabled?)
      errors << "One or more selected tools are not reservable" if tools.any? { |tool| !tool.reservable || tool.disabled? }

      if attributes[:start_at].present? && attributes[:end_at].present? && resources.present?
        start_date = attributes[:start_at].in_time_zone(ZONE).to_date
        today = Time.current.in_time_zone(ZONE).to_date
        strict_horizon = resources.map(&:reservation_horizon_days).min
        errors << "Reservation is outside the allowed booking window" if start_date > today + strict_horizon

        duration_hours = (attributes[:end_at] - attributes[:start_at]) / 1.hour
        strict_duration = resources.map(&:max_reservation_duration_hours).min.to_f
        errors << "Reservation exceeds the maximum duration" if duration_hours > strict_duration
      end

      prerequisite_ids = if attributes[:reservation_scope] == "shop"
        Array(shop.reservation_prerequisite_tool_ids).map(&:to_s)
      else
        tools.flat_map(&:effective_reservation_prerequisite_ids).uniq
      end
      checked_out_ids = ToolCheckout.where(member_id: member.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
      missing_ids = prerequisite_ids - checked_out_ids
      missing = Tool.where(:id.in => missing_ids).map { |tool| { id: tool.id.to_s, name: tool.name } }
      errors << "Required tool checkouts are missing" if missing_ids.present?

      if attributes[:start_at].present? && attributes[:end_at].present?
        overlapping = overlapping_reservations(attributes[:start_at], attributes[:end_at], reservation)
        shop_overlaps = overlapping.where(shop_id: shop.id)

        if attributes[:reservation_scope] == "shop"
          conflicts << "A tool in this shop is already reserved" if shop_overlaps.where(reservation_scope: "tools").exists?
          shop_count = shop_overlaps.where(reservation_scope: "shop").count
          conflicts << "The shop has reached its reservation capacity" if shop_count >= shop.max_concurrent_reservations
        else
          conflicts << "The entire shop is already reserved" if shop_overlaps.where(reservation_scope: "shop").exists?
          tools.each do |tool|
            count = shop_overlaps.where(reservation_scope: "tools", tool_ids: tool.id.to_s).count
            conflicts << "#{tool.name} has reached its reservation capacity" if count >= tool.max_concurrent_reservations
          end
        end

        member_overlap = overlapping.where(member_id: member.id).exists?
        approval_reasons << "overlapping_member_reservation" if member_overlap
      end

      approval_reasons << "resource_requires_approval" if resources.any?(&:reservation_requires_approval)

      {
        errors: errors.uniq,
        conflicts: conflicts.uniq,
        missing_prerequisites: missing,
        approval_reasons: approval_reasons.uniq
      }
    rescue Mongoid::Errors::DocumentNotFound, Mongoid::Errors::InvalidFind
      {
        errors: ["Selected shop was not found"],
        conflicts: [],
        missing_prerequisites: [],
        approval_reasons: []
      }
    end

    def overlapping_reservations(start_at, end_at, reservation)
      criteria = Reservation.blocking.where(:start_at.lt => end_at, :end_at.gt => start_at)
      criteria = criteria.where(:id.ne => reservation.id) if reservation
      criteria
    end

    def half_hour?(time)
      time.present? && (time.min == 0 || time.min == 30) && time.sec == 0
    end

    def material_edit?(reservation, attributes)
      reservation.shop_id.to_s != attributes[:shop_id].to_s ||
        reservation.reservation_scope != attributes[:reservation_scope] ||
        Array(reservation.tool_ids).map(&:to_s).sort != Array(attributes[:tool_ids]).map(&:to_s).sort ||
        reservation.start_at != attributes[:start_at] ||
        reservation.end_at != attributes[:end_at]
    end

    def raise_for_evaluation!(evaluation)
      raise ::Error::UnprocessableEntity.new(evaluation[:errors].join(". ")) if evaluation[:errors].present?
      raise ::Error::Conflict.new(evaluation[:conflicts].join(". ")) if evaluation[:conflicts].present?
    end

    def with_shop_lock(shop_id)
      token = SecureRandom.uuid
      key = "reservation_lock/shop/#{shop_id}"
      acquired = REDIS.set(key, token, nx: true, ex: LOCK_TTL_SECONDS)
      raise ::Error::Conflict.new("Reservation processing is busy; please retry") unless acquired

      yield
    rescue Redis::BaseError => error
      raise ::Error::Conflict.new("Reservation processing is temporarily unavailable: #{error.message}")
    ensure
      if key && token
        begin
          REDIS.eval(
            "if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
            keys: [key],
            argv: [token]
          )
        rescue Redis::BaseError
          nil
        end
      end
    end

    def with_shop_locks(shop_ids, &block)
      ids = Array(shop_ids).compact.map(&:to_s).uniq.sort
      acquire = lambda do |index|
        return block.call if index >= ids.length

        with_shop_lock(ids[index]) { acquire.call(index + 1) }
      end
      acquire.call(0)
    end

    def enqueue_calendar_sync(reservation)
      ReservationCalendarSyncJob.perform_later(reservation.id.to_s)
    end
  end
end
