class CheckoutApproverVolunteering
  def self.create!(member:, tool:, note: nil)
    raise Error::UnprocessableEntity.new("You must have an active checkout for this tool") unless
      ToolCheckout.where(member_id: member.id, tool_id: tool.id, revoked_at: nil).exists?
    raise Error::UnprocessableEntity.new("Your membership must be active and current") unless member.valid_for_checkout_request?
    if CheckoutApprover.find_by(member_id: member.id)&.can_approve_tool?(tool)
      raise Error::UnprocessableEntity.new("You are already an approver for this tool")
    end

    request = CheckoutApproverRequest.create!(member: member, tool: tool, note: note.presence)
    notify_resource_managers(request)
    request
  rescue Mongo::Error::OperationFailure
    raise Error::UnprocessableEntity.new("A volunteer request is already open for this tool")
  end

  def self.approve!(request:, actor:, note: nil)
    approver = CheckoutMutationLock.with(member_id: request.member_id, tool_id: request.tool_id) do
      request.reload
      authorize_decision!(request, actor)
      raise Error::UnprocessableEntity.new("The volunteer no longer has an active checkout") unless
        ToolCheckout.where(member_id: request.member_id, tool_id: request.tool_id, revoked_at: nil).exists?

      record = CheckoutApprover.find_or_initialize_by(member_id: request.member_id)
      record.tool_ids = (Array(record.tool_ids).map(&:to_s) + [request.tool_id.to_s]).uniq
      record.save!
      request.update!(status: "approved", decision_note: note.presence, decided_at: Time.current)
      record
    end
    notify_requestor(request)
    approver
  end

  def self.decline!(request:, actor:, note: nil)
    CheckoutMutationLock.with(member_id: request.member_id, tool_id: request.tool_id) do
      request.reload
      authorize_decision!(request, actor)
      request.update!(status: "declined", decision_note: note.presence, decided_at: Time.current)
    end
    notify_requestor(request)
    request
  end

  def self.revoke_for!(member_id:, tool_id:)
    CheckoutApproverRequest.where(member_id: member_id, tool_id: tool_id, status: "open").update_all(status: "revoked")
    approver = CheckoutApprover.find_by(member_id: member_id)
    return unless approver
    approver.tool_ids = Array(approver.tool_ids).reject { |id| id.to_s == tool_id.to_s }
    if approver.tool_ids.empty? && Array(approver.shop_ids).empty?
      approver.destroy!
    else
      approver.save!
    end
  end

  def self.notify_resource_managers(request)
    Member.where(:resource_manager_shop_ids.in => [request.tool.shop_id.to_s]).each do |manager|
      slack_id = SlackUser.find_by(member_id: manager.id)&.slack_id
      next if slack_id.blank? || manager.direct_notifications_suppressed?
      Service::SlackConnector.send_slack_message(
        "*#{request.member.fullname}* volunteered to approve checkouts for *#{request.tool.name}* in *#{request.tool.shop.name}*.\n" \
        "Checked out: #{checkout_date(request)}\nJoined makerspace: #{member_join_date(request.member)}" \
        "#{request.note.present? ? "\nNote: #{request.note}" : ""}\n" \
        "Open `/checkout` and choose View open requests to review it.", slack_id)
    rescue => error
      Service::ErrorReporter.notify(error, context: { phase: "notify checkout volunteer RM", request_id: request.id.to_s })
    end
  end

  def self.authorize_decision!(request, actor)
    raise Error::Forbidden.new("Only a resource manager for this shop can decide this request") unless
      actor.manages_shop?(request.tool.shop_id)
    raise Error::UnprocessableEntity.new("This volunteer request is no longer open") unless request.open?
  end

  def self.notify_requestor(request)
    slack_id = SlackUser.find_by(member_id: request.member_id)&.slack_id
    return if slack_id.blank?
    status = request.status == "approved" ? "approved" : "declined"
    message = "Your request to approve checkouts for *#{request.tool.name}* in *#{request.tool.shop.name}* was *#{status}*."
    message += "\nRM note: #{request.decision_note}" if request.decision_note.present?
    Service::SlackConnector.send_slack_message(message, slack_id)
  rescue => error
    Service::ErrorReporter.notify(error, context: { phase: "notify checkout volunteer", request_id: request.id.to_s })
  end

  def self.checkout_date(request)
    checkout = ToolCheckout.where(member_id: request.member_id, tool_id: request.tool_id, revoked_at: nil)
      .order_by(checked_out_at: :desc).first
    checkout&.checked_out_at&.to_date&.iso8601 || "Unknown"
  end

  def self.member_join_date(member)
    value = member.startDate
    value.respond_to?(:to_date) ? value.to_date.iso8601 : value.to_s.presence || "Unknown"
  end
  private_class_method :notify_resource_managers, :notify_requestor, :authorize_decision!, :checkout_date, :member_join_date
end
