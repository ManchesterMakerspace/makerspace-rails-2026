class SlackReservationModal
  POLICY_TEXT_LIMIT = 2_900
  SCOPE_ACTION_ID = "reservation_scope_changed"
  TOOLS_ACTION_ID = "reservation_tools_changed"

  class << self
    def build(shop, member, response_url: nil, slack_user_id: nil, reservation_scope: nil, tool_ids: nil,
      title: nil, date: nil, start_time: nil, duration: nil)
      tools = reservable_tools(shop)
      raise ::Error::UnprocessableEntity.new("This shop has more than 100 reservable tools; use the portal") if tools.length > 100
      raise ::Error::UnprocessableEntity.new("This shop has no reservable resources") unless shop.reservable || tools.present?

      scope_options = []
      scope_options << option("Entire shop", "shop") if shop.reservable
      scope_options << option("One or more tools", "tools") if tools.present?
      reservation_scope = valid_scope(reservation_scope, scope_options)
      selected_tools = selected_tools(tools, reservation_scope, tool_ids)
      resources = ReservationPolicy.resources(
        shop: shop, reservation_scope: reservation_scope, tools: selected_tools
      )
      policy = ReservationPolicy.aggregate(resources)
      scheduling_window = ReservationPolicy.scheduling_window(resources)
      durations = scheduling_window[:compatible] ? duration_options(policy) : []
      if scheduling_window[:compatible] && durations.empty?
        full_day_names = resources.select(&:reservation_full_day).map(&:name)
        limiting_names = resources.select do |resource|
          resource.max_reservation_duration_hours.to_f == policy[:maximum_duration_hours]
        end.map(&:name)
        scheduling_window = scheduling_window.merge(
          compatible: false,
          reason: "No duration is valid: #{full_day_names.join(', ')} require whole days, but " \
            "#{limiting_names.join(', ')} limit duration to #{format_hours(policy[:maximum_duration_hours])}."
        )
      end
      selected_duration = retained_duration(durations, duration)

      blocks = [
        input("title", "title", "Title", { type: "plain_text_input", initial_value: title }.compact),
        input("scope", SCOPE_ACTION_ID, "Reserve", {
          type: "radio_buttons",
          options: scope_options,
          initial_option: scope_options.find { |choice| choice[:value] == reservation_scope }
        }, dispatch_action: true)
      ]
      if tools.present?
        tool_element = {
          type: "multi_static_select",
          action_id: TOOLS_ACTION_ID,
          placeholder: plain("Select tools"),
          options: tools.map { |tool| option(tool.name, tool.id.to_s) }
        }
        tool_element[:initial_options] = selected_tools.map { |tool| option(tool.name, tool.id.to_s) } if selected_tools.present?
        blocks << input("tools", TOOLS_ACTION_ID, "Tools", tool_element, optional: reservation_scope != "tools", dispatch_action: true)
      end
      blocks << input("date", "date", "Date", {
          type: "datepicker",
          initial_date: valid_date(date) || Time.current.in_time_zone(ReservationService::ZONE).to_date.iso8601
        })
      unless policy[:full_day]
        blocks << input("start_time", "start_time", "Start time", {
          type: "timepicker",
          initial_time: valid_time(start_time) || next_half_hour.strftime("%H:%M")
        })
      end
      if durations.present?
        blocks << input("duration", "duration", "Duration", {
          type: "static_select",
          placeholder: plain("Select duration"),
          options: durations,
          initial_option: selected_duration
        })
      end
      blocks << policy_alert(shop, reservation_scope, selected_tools, member, policy, scheduling_window)

      view = {
        type: "modal",
        callback_id: "reservation_submit",
        notify_on_close: true,
        private_metadata: {
          shop_id: shop.id.to_s,
          member_id: member.id.to_s,
          response_url: response_url,
          slack_user_id: slack_user_id
        }.compact.to_json,
        title: plain("Reserve #{shop.name}".first(24)),
        close: plain("Cancel"),
        blocks: blocks
      }
      view[:submit] = plain("Reserve") if scheduling_window[:compatible] && durations.present?
      view
    end

    def update(shop:, member:, response_url:, slack_user_id:, reservation_scope:, tool_ids:,
      title:, date:, start_time:, duration:)
      build(
        shop,
        member,
        response_url: response_url,
        slack_user_id: slack_user_id,
        reservation_scope: reservation_scope,
        tool_ids: tool_ids,
        title: title,
        date: date,
        start_time: start_time,
        duration: duration
      )
    end

    def policy_summary(shop:, reservation_scope:, tools:, member:, policy: nil, scheduling_window: nil)
      resources = ReservationPolicy.resources(
        shop: shop, reservation_scope: reservation_scope, tools: tools
      )
      policy ||= ReservationPolicy.aggregate(resources)
      return "Select one or more tools to see the effective reservation rules." if resources.empty?
      scheduling_window ||= ReservationPolicy.scheduling_window(resources)

      lines = ["*Effective reservation rules for #{resource_names(resources)}*"]
      lines << "• Book up to #{policy[:horizon_days]} #{'day'.pluralize(policy[:horizon_days])} ahead."
      lines << "• At least #{format_hours(policy[:minimum_advance_notice_hours])} advance notice."
      lines << "• Same-day reservations are not allowed." if policy[:prohibit_same_day]
      lines << "• Maximum duration: #{format_duration(policy[:maximum_duration_hours], policy[:full_day])}."
      lines << "• Reservations must use whole days (midnight to midnight)." if policy[:full_day]
      lines << "• Manager approval is required." if policy[:requires_approval]
      lines << "• *Unavailable combination:* #{scheduling_window[:reason]}" unless scheduling_window[:compatible]
      prerequisites = ReservationPolicy.prerequisite_names(
        shop: shop, reservation_scope: reservation_scope, tools: tools, member: member
      )
      lines << if prerequisites.present?
        "• Required active checkout(s): #{prerequisites.join(', ')}."
      else
        "• No checkout prerequisites."
      end

      add_rule_differences(lines, resources)
      lines.join("\n").first(POLICY_TEXT_LIMIT)
    end

    private

    def reservable_tools(shop)
      Tool.where(shop_id: shop.id, reservable: true, :disabled.ne => true).order_by(name: :asc).to_a
    end

    def valid_scope(requested, scope_options)
      values = scope_options.map { |choice| choice[:value] }
      values.include?(requested) ? requested : values.first
    end

    def selected_tools(tools, reservation_scope, tool_ids)
      return reservation_scope == "tools" ? tools.first(1) : [] if tool_ids.nil?

      ids = Array(tool_ids).map(&:to_s)
      selected = tools.select { |tool| ids.include?(tool.id.to_s) }
      selected
    end

    def duration_options(policy)
      maximum = policy[:maximum_duration_hours].to_f
      if policy[:full_day]
        1.upto((maximum / 24).floor).map do |days|
          option("#{days} #{'day'.pluralize(days)}", "days:#{days}")
        end
      else
        half_hours = (1..[(maximum * 2).floor, 10].min).map { |step| step / 2.0 }
        whole_hours = 6.upto(maximum.floor).to_a
        (half_hours + whole_hours).map do |hours|
          option(format_hours(hours), "hours:#{hours}")
        end
      end
    end

    def policy_alert(shop, reservation_scope, tools, member, policy, scheduling_window)
      {
        type: "alert",
        block_id: "reservation_policy",
        level: "info",
        text: plain(policy_summary(
          shop: shop,
          reservation_scope: reservation_scope,
          tools: tools,
          member: member,
          policy: policy,
          scheduling_window: scheduling_window
        ))
      }
    end

    def retained_duration(options, requested)
      return options.first if requested.blank?

      exact = options.find { |choice| choice[:value] == requested }
      return exact if exact

      requested_unit, requested_value = requested.to_s.split(":", 2)
      same_unit = options.select { |choice| choice[:value].start_with?("#{requested_unit}:") }
      return options.first if same_unit.empty?

      requested_amount = requested_value.to_f
      same_unit.reverse.find do |choice|
        choice[:value].split(":", 2).last.to_f <= requested_amount
      end || same_unit.first
    end

    def valid_date(value)
      Date.iso8601(value.to_s).iso8601 if value.present?
    rescue Date::Error
      nil
    end

    def valid_time(value)
      value if value.to_s.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)
    end

    def add_rule_differences(lines, resources)
      return if resources.length < 2

      fields = {
        reservation_horizon_days: "booking window",
        minimum_advance_notice_hours: "advance notice",
        prohibit_same_day_reservations: "same-day rule",
        max_reservation_duration_hours: "maximum duration",
        reservation_full_day: "full-day rule",
        reservation_requires_approval: "approval rule"
      }
      differing = fields.select { |field, _label| resources.map { |resource| resource.public_send(field) }.uniq.length > 1 }
      return if differing.empty?

      lines << "• Rules differ by resource:"
      resources.each do |resource|
        details = differing.map do |field, label|
          "#{label} #{format_rule_value(field, resource.public_send(field))}"
        end
        lines << "  ◦ *#{resource.name}*: #{details.join('; ')}"
      end
    end

    def format_rule_value(field, value)
      case field
      when :reservation_horizon_days then "#{value}d"
      when :minimum_advance_notice_hours, :max_reservation_duration_hours then format_hours(value)
      else value ? "yes" : "no"
      end
    end

    def resource_names(resources)
      resources.map { |resource| "*#{resource.name}*" }.join(", ")
    end

    def format_duration(hours, full_day)
      return "#{(hours / 24).floor} #{'day'.pluralize((hours / 24).floor)}" if full_day && hours >= 24

      format_hours(hours)
    end

    def format_hours(hours)
      number = hours.to_f
      label = number == number.to_i ? number.to_i : number
      "#{label} #{'hour'.pluralize(number)}"
    end

    def plain(text)
      { type: "plain_text", text: text, emoji: true }
    end

    def option(text, value)
      { text: plain(text.first(75)), value: value }
    end

    def input(block_id, action_id, label, element, optional: false, dispatch_action: false)
      {
        type: "input",
        block_id: block_id,
        optional: optional,
        dispatch_action: dispatch_action,
        label: plain(label),
        element: element.merge(action_id: action_id)
      }
    end

    def next_half_hour
      now = Time.current.in_time_zone(ReservationService::ZONE)
      rounded_minute = now.min < 30 ? 30 : 0
      result = now.change(min: rounded_minute, sec: 0)
      rounded_minute.zero? ? result + 1.hour : result
    end
  end
end
