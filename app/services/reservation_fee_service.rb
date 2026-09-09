class ReservationFeeService
  class << self
    def snapshot(attributes, reservation = nil)
      resources = attributes[:reservation_scope] == "shop" ? Shop.where(id: attributes[:shop_id]).to_a : Tool.where(:id.in => attributes[:tool_ids]).to_a
      resources.map do |resource|
        existing = Array(reservation&.fee_rule_snapshot).find { |entry| entry["resourceId"] == resource.id.to_s }
        next existing if existing
        rules = Array(resource.duration_fees).map do |raw|
          rule = raw.to_h.stringify_keys
          option = InvoiceOption.where(id: rule["invoice_option_id"], resource_class: "fee", disabled: false).first
          rule.merge("name" => option&.name, "amount" => option&.amount)
        end
        { "resourceId" => resource.id.to_s, "rules" => rules }
      end
    end

    def quote(resources:, start_at:, end_at:, full_day:, reservation: nil, rule_snapshot: nil)
      return [] unless start_at && end_at && end_at > start_at

      hours = duration_hours(start_at, end_at, full_day)
      resources.filter_map do |resource|
        saved = Array(rule_snapshot || reservation&.fee_rule_snapshot).find { |entry| entry["resourceId"] == resource.id.to_s }
        candidates = Array(saved ? saved["rules"] : resource.duration_fees).map { |rule| rule.to_h.stringify_keys }
        rule = candidates.select do |fee|
          day = ActiveModel::Type::Boolean.new.cast(fee["full_day"])
          day ? full_day : hours >= fee["minimum_hours"].to_f
        end.max_by do |fee|
          day = ActiveModel::Type::Boolean.new.cast(fee["full_day"])
          [day ? 24 : fee["maximum_hours"].to_f, day ? 24 : fee["minimum_hours"].to_f]
        end
        next unless rule

        option = InvoiceOption.where(id: rule["invoice_option_id"], resource_class: "fee", disabled: false).first unless saved
        price = saved ? rule["amount"] : option&.amount
        name = saved ? rule["name"] : option&.name
        raise Error::UnprocessableEntity.new("A reservation fee is unavailable; please contact a resource manager") unless price.to_f.positive?
        unit_hours = ActiveModel::Type::Boolean.new.cast(rule["full_day"]) ? 24 : rule["maximum_hours"].to_f
        units = (hours / unit_hours).ceil
        { resourceId: resource.id.to_s, resourceName: resource.name, invoiceOptionId: rule["invoice_option_id"].to_s,
          name: name, unitHours: unit_hours, units: units, unitAmount: price,
          amount: (BigDecimal(price.to_s) * units).round(2).to_f }
      end
    end

    def duration_hours(start_at, end_at, full_day)
      return (end_at - start_at) / 1.hour unless full_day
      (end_at.in_time_zone(ReservationService::ZONE).to_date - start_at.in_time_zone(ReservationService::ZONE).to_date).to_i * 24.0
    end

    def total(lines)
      lines.sum { |line| BigDecimal((line[:amount] || line["amount"]).to_s) }.round(2).to_f
    end

    def amount_due(lines, reservation = nil)
      return total(lines) unless reservation
      current = reservation.fee_invoice
      paid = Array(reservation.previous_invoice_ids).filter_map { |id| Invoice.where(id: id).first }.select(&:settled).sum(&:amount)
      paid += current.amount if current&.settled
      amount = [total(lines) - paid, 0].max.round(2)
      amount.zero? && current && !current.settled ? current.amount : amount
    end

    def confirmation(lines, reservation = nil)
      Digest::SHA256.hexdigest({ lines: lines, amount: amount_due(lines, reservation) }.to_json)
    end

    def overdue_fees?(member)
      Invoice.where(member_id: member.id, resource_class: "fee", settled_at: nil).any? do |invoice|
        invoice.due_date && invoice.due_date < Time.current
      end
    end

    def confirm!(lines, attributes, reservation = nil)
      invoice = reservation&.fee_invoice
      if invoice && !invoice.settled && (invoice.transaction_id.present? || invoice.locked_at.present?)
        raise Error::UnprocessableEntity.new("Payment is processing. Please wait before changing this reservation")
      end
      return if amount_due(lines, reservation).zero?
      token = confirmation(lines, reservation)
      unless attributes.to_h.symbolize_keys[:fee_confirmation] == token
        raise Error::UnprocessableEntity.new("Please review and approve the reservation fee of $#{format('%.2f', amount_due(lines, reservation))}. Use the member portal to confirm the fee")
      end
    end

    def apply!(reservation, lines, approved: false)
      lines = Array(lines).map { |line| line.to_h.symbolize_keys }
      if reservation.approval_reasons.present? && !approved
        reservation.update!(fee_snapshot: lines, status: "pending")
        return
      end
      current = reservation.fee_invoice || Invoice.where(reservation_id: reservation.id.to_s).order_by(created_at: :desc).first
      reservation.set(invoice: current.id.to_s) if current && reservation.invoice.blank?
      paid = Array(reservation.previous_invoice_ids).filter_map { |id| Invoice.where(id: id).first }.select(&:settled).sum(&:amount)
      paid += current.amount if current&.settled
      amount = [total(lines) - paid, 0].max.round(2)
      details = lines.map { |line| "#{line[:resourceName]}: #{line[:units]} × #{line[:name]} ($#{format('%.2f', line[:unitAmount])})" }.join("; ")
      if current && !current.settled
        if amount.positive?
          current.update!(amount: amount, due_date: reservation.start_at - 4.hours, description: details)
        else
          # An accepted charge survives edits and cancellations; never erase debt.
          amount = current.amount
        end
      elsif amount.positive?
        history = Array(reservation.previous_invoice_ids)
        history |= [current.id.to_s] if current
        invoice = Invoice.create!(member: reservation.member, resource_class: "fee", resource_id: reservation.member_id.to_s,
          name: "Reservation: #{reservation.title}", description: details, amount: amount, quantity: 1,
          due_date: reservation.start_at - 4.hours, reservation_id: reservation.id.to_s)
        reservation.set(invoice: invoice.id.to_s, previous_invoice_ids: history)
      end
      reservation.update!(fee_snapshot: lines, status: amount.positive? ? "unpaid" : (reservation.approval_reasons.present? ? "pending" : "approved"))
    end

    def reconcile!(reservation)
      invoice = reservation.fee_invoice || Invoice.where(reservation_id: reservation.id.to_s).order_by(created_at: :desc).first
      reservation.set(invoice: invoice.id.to_s) if invoice && reservation.invoice.blank?
      return unless invoice
      changed = false
      ReservationService.send(:with_shop_lock, reservation.shop_id) do
        reservation.reload
        invoice.reload
        if reservation.blocking? && !invoice.settled && reservation.status != "unpaid"
          reservation.update!(status: "unpaid")
          changed = true
          ReservationService.send(:enqueue_external_syncs, reservation)
        end
        if reservation.status == "unpaid"
          if invoice.settled
            # Payment after the start cannot reclaim capacity already released.
            status = invoice.settled_at >= reservation.start_at ? "cancelled" : (reservation.approval_reasons.present? ? "pending" : "approved")
            reservation.update!(status: status)
            changed = true
            ReservationService.send(:enqueue_external_syncs, reservation)
          elsif invoice.due_date < Time.current && reservation.start_at <= Time.current
            reservation.update!(status: "cancelled", decision_note: "Unpaid reservation cancelled at start time")
            changed = true
            ReservationService.send(:enqueue_external_syncs, reservation)
          end
        end
      end
      ReservationFeeNotificationJob.perform_later(reservation.id.to_s) unless changed
    end
  end
end
