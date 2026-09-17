class ReservationPolicy
  class << self
    def resources(shop:, reservation_scope:, tools:)
      reservation_scope == "shop" ? [shop] : Array(tools)
    end

    def aggregate(resources)
      selected = Array(resources)
      return {} if selected.empty?

      {
        horizon_days: selected.map(&:reservation_horizon_days).min,
        minimum_advance_notice_hours: selected.map(&:minimum_advance_notice_hours).max.to_f,
        prohibit_same_day: selected.any?(&:prohibit_same_day_reservations),
        maximum_duration_hours: selected.map(&:max_reservation_duration_hours).min.to_f,
        full_day: selected.any?(&:reservation_full_day),
        requires_approval: selected.any?(&:reservation_requires_approval)
      }
    end

    def scheduling_window(resources, now: Time.current.in_time_zone(ReservationService::ZONE))
      selected = Array(resources)
      return { compatible: false, reason: "Select at least one reservable resource." } if selected.empty?

      policy = aggregate(selected)
      notice_start = now + policy[:minimum_advance_notice_hours].hours
      earliest_start = Time.at((notice_start.to_f / 30.minutes).floor * 30.minutes).in_time_zone(ReservationService::ZONE)
      if policy[:full_day]
        earliest_date = [earliest_start.to_date, now.to_date + 1.day].max
        earliest_start = earliest_date.in_time_zone(ReservationService::ZONE)
        earliest_start = (earliest_date + 1.day).in_time_zone(ReservationService::ZONE) if earliest_start < notice_start
      elsif policy[:prohibit_same_day] && earliest_start.to_date == now.to_date
        earliest_start = (now.to_date + 1.day).in_time_zone(ReservationService::ZONE)
      end
      final_start_date = now.to_date + policy[:horizon_days]
      compatible = earliest_start.to_date <= final_start_date
      result = { compatible: compatible, earliest_start: earliest_start, final_start_date: final_start_date }
      return result if compatible

      notice_resources = selected.select do |resource|
        resource.minimum_advance_notice_hours.to_f == policy[:minimum_advance_notice_hours] ||
          resource.prohibit_same_day_reservations
      end
      horizon_resources = selected.select { |resource| resource.reservation_horizon_days == policy[:horizon_days] }
      result.merge(reason: "These resources cannot be reserved together: #{notice_resources.map(&:name).join(', ')} " \
        "require an earliest start of #{earliest_start.strftime('%B %-d at %H:%M')}, but " \
        "#{horizon_resources.map(&:name).join(', ')} limit booking to #{final_start_date.strftime('%B %-d')}.")
    end

    def prerequisite_ids(shop:, reservation_scope:, tools:, member: nil)
      selected_tools = Array(tools)
      ids = if reservation_scope == "shop"
        Array(shop.reservation_prerequisite_tool_ids).map(&:to_s)
      else
        selected_tools.flat_map(&:effective_reservation_prerequisite_ids).uniq
      end

      if member&.status == "pending" && reservation_scope == "tools"
        explicit_ids = selected_tools.flat_map do |tool|
          Array(tool.reservation_prerequisite_tool_ids).map(&:to_s)
        end
        ids -= selected_tools.select(&:allow_pending).map { |tool| tool.id.to_s } - explicit_ids
      end
      ids
    end

    def prerequisite_names(shop:, reservation_scope:, tools:, member: nil)
      ids = prerequisite_ids(
        shop: shop,
        reservation_scope: reservation_scope,
        tools: tools,
        member: member
      )
      names_by_id = Tool.where(:id.in => ids).to_a.index_by { |tool| tool.id.to_s }
      ids.map { |id| names_by_id[id]&.name || "Unknown tool" }
    end
  end
end
