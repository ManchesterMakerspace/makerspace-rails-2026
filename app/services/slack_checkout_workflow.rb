# Slack display labels are never inputs to this state machine. Every transition
# resolves the signed Slack identity and all selected records again from Mongo.
class SlackCheckoutWorkflow
  class Rejected < StandardError; end
  class FieldError < Rejected
    attr_reader :field
    def initialize(field, message)
      @field = field
      super(message)
    end
  end

  BACK_STEPS = {
    "active" => "menu", "requests" => "menu", "request_tools" => "menu", "volunteer" => "menu",
    "shop_active" => "menu", "shop_requests" => "menu", "shop_request_tools" => "menu", "shop_volunteer" => "menu",
    "request_new" => "request_tools", "request_detail" => "requests",
    "request_edit" => "request_detail", "request_cancel" => "request_detail",
    "request_approve" => "request_detail", "checkout_detail" => "active",
    "volunteer_confirm" => "volunteer", "volunteer_detail" => "requests",
    "volunteer_approve" => "volunteer_detail", "volunteer_decline" => "volunteer_detail",
    "done" => "menu", "alert" => "menu"
  }.freeze
  REQUEST_STEPS = %w[request_detail request_edit request_cancel request_approve].freeze
  SUBMIT_STEPS = %w[request_new request_edit request_cancel request_approve volunteer_confirm volunteer_approve volunteer_decline].freeze

  def initialize(payload)
    @payload = payload
    parsed = SlackCheckoutModal.decode_metadata(payload.dig("view", "private_metadata").to_s)
    raise Rejected, "This checkout form is invalid. Open /checkout again." unless parsed.is_a?(Hash)
    @metadata = parsed.slice(*SlackCheckoutModal::METADATA_KEYS)
  rescue JSON::ParserError, ArgumentError
    raise Rejected, "This checkout form has expired. Open /checkout again."
  end

  def call
    load_context!
    if @payload["type"] == "view_submission"
      return submit!
    else
      navigate!
    end
    build
  end

  def alert(message)
    SlackCheckoutModal.new(metadata: @metadata.except("record_id").merge("step" => "alert"), alert: message).build
  end

  private

  def step
    @metadata["step"]
  end

  def reject!(message = "That record is no longer available or you are not authorized to use it.")
    raise Rejected, message
  end

  def find_record(model, id)
    return unless BSON::ObjectId.legal?(id.to_s)
    model.find_by(id: id)
  end

  def load_context!
    slack_id = @payload.dig("user", "id")
    reject!("This form belongs to another Slack account. Open /checkout again.") unless
      slack_id.present? && slack_id == @metadata["slack_user_id"]
    linked = SlackUser.find_by(slack_id: slack_id)
    @member = linked && find_record(Member, linked.member_id)
    reject!("Your linked account changed. Open /checkout again.") unless
      @member && @member.id.to_s == @metadata["member_id"]
    message = SlackCheckoutModal.membership_error(@member)
    reject!(message) if message
    reject!("This checkout step is invalid. Open /checkout again.") unless step.in?(["menu"] + BACK_STEPS.keys)
    @shop = find_record(Shop, @metadata["shop_id"]) if @metadata["shop_id"].present?
    reject!("This shop is no longer available.") if @metadata["shop_id"].present? && (!@shop || @shop.disabled?)
    reject!("Select a shop first.") unless @shop || step == "menu" || step.start_with?("shop_") || step == "alert"
    @tool = @request = @volunteer_request = @checkout = nil
    case step
    when "request_new"
      @tool = available_tool!(@metadata["record_id"])
      error = ToolCheckoutRequestEligibility.new(member: @member, tool: @tool).error
      reject!(error) if error
    when *REQUEST_STEPS
      @request = visible_request!(@metadata["record_id"])
      @tool = available_tool!(@request.tool_id)
      if step.in?(%w[request_edit request_cancel])
        reject!("Only the requester can edit or cancel this request.") unless @request.member_id == @member.id
      elsif step == "request_approve"
        reject!("You can no longer approve this tool.") unless @request.member_id != @member.id && can_approve?(@tool)
      end
    when "checkout_detail"
      @checkout = find_record(ToolCheckout, @metadata["record_id"])
      reject! unless @checkout && @checkout.member_id == @member.id && @checkout.active?
      @tool = available_tool!(@checkout.tool_id)
    when "volunteer_confirm"
      @tool = volunteer_tool!(@metadata["record_id"])
    when "volunteer_detail", "volunteer_approve", "volunteer_decline"
      @volunteer_request = find_record(CheckoutApproverRequest, @metadata["record_id"])
      reject! unless @volunteer_request&.open?
      @tool = available_tool!(@volunteer_request.tool_id)
      reject!("You are not authorized to review volunteers for this shop.") unless
        CheckoutApproverVolunteering.reviewer?(@member, @shop.id)
    end
  end

  def available_tool!(id)
    tool = find_record(Tool, id)
    reject! unless @shop && tool && tool.shop_id == @shop.id && !tool.disabled? && !tool.open
    reject!("This tool is not available to pending members.") if @member.status == "pending" && !tool.allow_pending
    tool
  end

  def can_approve?(tool)
    CheckoutCreation.authorized?(@member, tool)
  end

  def volunteer_tool!(id)
    tool = available_tool!(id)
    reject!("You must have an active checkout for this tool.") unless
      ToolCheckout.where(member_id: @member.id, tool_id: tool.id, revoked_at: nil).exists?
    reject!("You are already an approver for this tool.") if CheckoutApprover.find_by(member_id: @member.id)&.can_approve_tool?(tool)
    reject!("You already have an open volunteer request for this tool.") if
      CheckoutApproverRequest.where(member_id: @member.id, tool_id: tool.id, status: "open").exists?
    tool
  end

  def query
    CheckoutInteractionQuery.new(member: @member, shop: @shop)
  end

  def visible_request!(id)
    request = find_record(ToolCheckoutRequest, id)
    reject! unless request&.open?
    tool = available_tool!(request.tool_id)
    reject! unless request.member_id == @member.id || can_approve?(tool)
    requester = find_record(Member, request.member_id)
    reject! unless requester
    # Ignore this existing open request, but recheck membership, prerequisites,
    # availability and existing checkout records through the authoritative policy.
    error = ToolCheckoutRequestEligibility.new(member: requester, tool: tool, open_request_tool_ids: []).error
    reject!(error) if error
    request
  end

  def navigate!
    actions = @payload["actions"]
    reject! unless actions.is_a?(Array) && actions.length == 1 && actions.first.is_a?(Hash)
    action = actions.first
    id = action["action_id"]
    value = action.dig("selected_option", "value")
    if id == SlackCheckoutModal::BACK
      target = BACK_STEPS[step]
      reject! unless target && action["block_id"] == "checkout_navigation"
      @metadata.delete("record_id") unless target.in?(%w[request_detail volunteer_detail])
      @metadata["step"] = target
    elsif id == "#{SlackCheckoutModal::SHOP}_select"
      reject! unless !@shop && (step == "menu" || step.start_with?("shop_")) && action["block_id"] == SlackCheckoutModal::SHOP
      shop = find_record(Shop, value)
      reject!("That shop is no longer available.") unless shop && !shop.disabled?
      @metadata["shop_id"] = shop.id.to_s
      @metadata["step"] = step.delete_prefix("shop_")
    elsif step == "menu" && id == "#{SlackCheckoutModal::MENU}_select" && action["block_id"] == SlackCheckoutModal::MENU
      reject! unless SlackCheckoutModal::CHOICES.map(&:last).include?(value)
      @metadata["step"] = @shop ? value : "shop_#{value}"
    elsif step == "request_tools" && id == "#{SlackCheckoutModal::TOOL}_select" && action["block_id"] == SlackCheckoutModal::TOOL
      @metadata.merge!("step" => "request_new", "record_id" => value)
    elsif step == "requests" && id == "#{SlackCheckoutModal::REQUEST}_select" && action["block_id"] == SlackCheckoutModal::REQUEST
      if value.to_s.start_with?("volunteer:")
        @metadata.merge!("step" => "volunteer_detail", "record_id" => value.delete_prefix("volunteer:"))
      else
        @metadata.merge!("step" => "request_detail", "record_id" => value)
      end
    elsif step == "volunteer" && id == "#{SlackCheckoutModal::TOOL}_select" && action["block_id"] == SlackCheckoutModal::TOOL
      @metadata.merge!("step" => "volunteer_confirm", "record_id" => value)
    elsif step == "active" && id == "#{SlackCheckoutModal::CHECKOUT}_select" && action["block_id"] == SlackCheckoutModal::CHECKOUT
      @metadata.merge!("step" => "checkout_detail", "record_id" => value)
    elsif step == "request_detail" && action["block_id"] == "checkout_actions"
      target = { SlackCheckoutModal::EDIT => "request_edit", SlackCheckoutModal::CANCEL => "request_cancel",
                 SlackCheckoutModal::APPROVE => "request_approve" }[id]
      reject! unless target
      @metadata["step"] = target
    elsif step == "volunteer_detail" && action["block_id"] == "checkout_actions"
      target = { SlackCheckoutModal::APPROVE_VOLUNTEER => "volunteer_approve",
                 SlackCheckoutModal::DECLINE_VOLUNTEER => "volunteer_decline" }[id]
      reject! unless target
      @metadata["step"] = target
    else
      reject!("This action is no longer available. Open /checkout again.")
    end
    load_context!
  end

  def submit!
    reject! unless SUBMIT_STEPS.include?(step)
    note = @payload.dig("view", "state", "values", SlackCheckoutModal::NOTE, SlackCheckoutModal::NOTE, "value")
    if step.in?(%w[request_new request_edit volunteer_confirm volunteer_approve volunteer_decline]) &&
        (!note.nil? && (!note.is_a?(String) || note.length > 128))
      raise FieldError.new(SlackCheckoutModal::NOTE, "Note must be at most 128 characters.")
    end
    case step
    when "request_new"
      CheckoutRequestCreation.create!(member_id: @member.id, tool_id: @tool.id,
        shop_id: @shop.id, note: note, defer_notifications: true) { load_context! }
      message = "Your checkout request for #{CheckoutDisplay.escape(@tool.name.to_s.first(200))} has been created."
    when "request_approve"
      CheckoutCreation.create!(actor_id: @member.id, member_id: @request.member_id,
        tool_id: @tool.id, shop_id: @shop.id, source: "slack", request_id: @request.id, defer_notifications: true) { load_context! }
      message = "The checkout request for #{CheckoutDisplay.escape(@tool.name.to_s.first(200))} has been approved."
    when "volunteer_confirm"
      CheckoutApproverVolunteering.create!(member: @member, tool: @tool, note: note)
      message = "Your request to become a checkout approver for #{CheckoutDisplay.escape(@tool.name.to_s.first(200))} has been sent to the shop's resource managers."
    when "volunteer_approve"
      CheckoutApproverVolunteering.approve!(request: @volunteer_request, actor: @member, note: note)
      message = "#{CheckoutDisplay.escape(@volunteer_request.member.fullname)} can now approve checkouts for #{CheckoutDisplay.escape(@tool.name)}."
    when "volunteer_decline"
      CheckoutApproverVolunteering.decline!(request: @volunteer_request, actor: @member, note: note)
      message = "The volunteer request from #{CheckoutDisplay.escape(@volunteer_request.member.fullname)} was declined."
    else
      CheckoutMutationLock.with(member_id: @request.member_id, tool_id: @tool.id) do
        load_context!
        if step == "request_edit"
          @request.update!(note: note)
          message = "Your request note has been saved."
        else
          @request.update!(status: "deleted")
          CheckoutNotificationJob.enqueue("cancellation", @request.id)
          message = "Your checkout request has been cancelled."
        end
      end
    end
    begin
      SlackCheckoutOutcomeJob.enqueue(message, @metadata["response_url"], @payload.dig("user", "id"))
    rescue => error
      SlackCheckoutOutcomeJob.report("enqueue", error_class: error.class.name)
    end
    :clear
  end

  def build
    options = { member: @member, shop: @shop, metadata: @metadata, tool: @tool,
      request: @request, volunteer_request: @volunteer_request, checkout: @checkout, alert: @message }
    case step
    when "request_tools"
      options[:tools] = query.requestable_tools
    when "requests"
      options[:requests] = query.visible_open_requests.to_a
      options[:volunteer_requests] = query.visible_volunteer_requests.to_a
    when "volunteer"
      options[:tools] = query.volunteerable_tools
    when "active"
      options[:checkouts] = query.listed_active_checkouts
    when "request_detail"
      options[:can_approve] = can_approve?(@tool)
    end
    SlackCheckoutModal.new(**options).build
  end
end
