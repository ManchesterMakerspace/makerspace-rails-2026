class CheckoutCreation
  def self.authorized?(actor, tool)
    actor && tool && SlackCheckoutModal.membership_error(actor).nil? &&
      (actor.status != "pending" || tool.allow_pending) &&
      (actor.role.in?(%w[admin board_member]) || actor.manages_shop?(tool.shop_id) ||
        (actor.valid_for_checkout_request? && CheckoutApprover.find_by(member_id: actor.id)&.can_approve_tool?(tool)))
  end

  def self.create!(actor_id:, member_id:, tool_id:, shop_id:, source:, request_id: nil, defer_notifications: false)
    checkout = CheckoutMutationLock.with(member_id: member_id, tool_id: tool_id) do
      yield if block_given? # Recheck the initiating Slack identity under the same lock.
      actor = Member.find_by(id: actor_id)
      member = Member.find_by(id: member_id)
      tool = Tool.find_by(id: tool_id)
      raise Error::Forbidden.new("You are not authorized to approve checkouts for this tool") unless authorized?(actor, tool)
      raise Error::UnprocessableEntity.new("Tool unavailable") unless member && tool.shop_id.to_s == shop_id.to_s
      request = ToolCheckoutRequest.find_by(id: request_id) if request_id
      if request_id && (!request&.open? || request.member_id != member.id || request.tool_id != tool.id)
        raise Error::UnprocessableEntity.new("This checkout request is no longer open or available")
      end
      error = ToolCheckoutRequestEligibility.new(member: member, tool: tool, open_request_tool_ids: []).error
      raise Error::UnprocessableEntity.new(error) if error
      ToolCheckout.create!(member: member, tool: tool, approved_by: actor,
        signed_off_via: source, checked_out_at: Time.current, checkout_request_id: request&.id,
        defer_users_channel_invitation: defer_notifications)
    end
    # This credit is deliberately silent: it is operational compensation for
    # an additional approver, not a member-submitted volunteer-credit event.
    CheckoutApproverCredit.award!(checkout)
    if defer_notifications
      CheckoutNotificationJob.enqueue("approval", checkout.id)
    else
      deliver_notifications(checkout)
    end
    checkout
  end

  def self.deliver_notifications(checkout, invite: false)
    if checkout.active?
      notify { checkout.invite_member_to_users_channel } if invite
      notify { checkout.send_checkout_slack_notification }
      notify { checkout.announce_checkout_success }
    end
    notify do
      Service::AuditLogger.log(log_type: "member", event_type: "tool_checkout_created",
        resource_type: "ToolCheckout", resource_id: checkout.id, actor: checkout.approved_by, subject: checkout.member,
        after_snapshot: { member_id: checkout.member_id.to_s, tool_id: checkout.tool_id.to_s,
          shop_name: checkout.tool.shop.name, tool_name: checkout.tool.name,
          approved_by: checkout.approved_by.fullname, signed_off_via: checkout.signed_off_via },
        message_details: "shop: #{checkout.tool.shop.name}, tool: #{checkout.tool.name}",
        slack_channel: Service::SlackConnector.logs_channel)
    end
    checkout
  end

  def self.notify
    yield
  rescue => error
    begin
      Service::ErrorReporter.notify("Checkout notification failed", context: { error_class: error.class.name })
    rescue
      Rails.logger.warn("[Checkout] notification reporting failed")
    end
  end
end
