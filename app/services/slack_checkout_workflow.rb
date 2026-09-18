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
    "active" => "menu", "requests" => "menu", "request_tools" => "menu",
    "shop_active" => "menu", "shop_requests" => "menu", "shop_request_tools" => "menu",
    "request_new" => "request_tools", "request_detail" => "requests",
    "request_edit" => "request_detail", "request_cancel" => "request_detail",
    "request_approve" => "request_detail", "checkout_detail" => "active",
    "done" => "menu", "alert" => "menu"
  }.freeze
  REQUEST_STEPS = %w[request_detail request_edit request_cancel request_approve].freeze
  SUBMIT_STEPS = %w[request_new request_edit request_cancel request_approve].freeze

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
      submit!
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
    @tool = @request = @checkout = nil
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
        reject!("You can no longer approve this tool.") unless can_approve?(@tool)
      end
    when "checkout_detail"
      @checkout = find_record(ToolCheckout, @metadata["record_id"])
      reject! unless @checkout && @checkout.member_id == @member.id && @checkout.active?
      @tool = available_tool!(@checkout.tool_id)
    end
  end

  def available_tool!(id)
    tool = find_record(Tool, id)
    reject! unless @shop && tool && tool.shop_id == @shop.id && !tool.disabled? && !tool.open
    reject!("This tool is not available to pending members.") if @member.status == "pending" && !tool.allow_pending
    tool
  end

  def can_approve?(tool)
    @member.role.in?(%w[admin board_member]) || @member.manages_shop?(tool.shop_id) ||
      (@member.valid_for_checkout_request? && CheckoutApprover.find_by(member_id: @member.id)&.can_approve_tool?(tool))
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
      @metadata.delete("record_id") unless target == "request_detail"
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
      @metadata.merge!("step" => "request_detail", "record_id" => value)
    elsif step == "active" && id == "#{SlackCheckoutModal::CHECKOUT}_select" && action["block_id"] == SlackCheckoutModal::CHECKOUT
      @metadata.merge!("step" => "checkout_detail", "record_id" => value)
    elsif step == "request_detail" && action["block_id"] == "checkout_actions"
      target = { SlackCheckoutModal::EDIT => "request_edit", SlackCheckoutModal::CANCEL => "request_cancel",
                 SlackCheckoutModal::APPROVE => "request_approve" }[id]
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
    if step.in?(%w[request_new request_edit]) && (!note.nil? && (!note.is_a?(String) || note.length > 128))
      raise FieldError.new(SlackCheckoutModal::NOTE, "Note must be at most 128 characters.")
    end
    with_lock do
      load_context!
      case step
      when "request_new"
        request = ToolCheckoutRequest.create!(member: @member, tool: @tool, note: note, request_date: Time.current)
        notify { request.announce_request }
        @message = "Your checkout request has been created."
      when "request_edit"
        @request.update!(note: note)
        @message = "Your request note has been saved."
      when "request_cancel"
        @request.update!(status: "deleted")
        notify { @request.remove_announcement }
        @message = "Your checkout request has been cancelled."
      when "request_approve"
        checkout = ToolCheckout.create!(member: @request.member, tool: @tool, approved_by: @member,
          signed_off_via: "slack", checked_out_at: Time.current)
        # The model closes the matching request and handles channel invitations.
        @request.update!(status: "closed", checked_out: checkout) if @request.reload.open?
        notify { checkout.send_checkout_slack_notification }
        notify { checkout.announce_checkout_success }
        notify do
          Service::AuditLogger.log(log_type: "member", event_type: "tool_checkout_created",
            resource_type: "ToolCheckout", resource_id: checkout.id, actor: @member, subject: checkout.member,
            after_snapshot: { tool_id: @tool.id.to_s, member_id: checkout.member_id.to_s, signed_off_via: "slack" })
        end
        @message = "The checkout request has been approved."
      end
    end
    @metadata = @metadata.except("record_id").merge("step" => "done")
  end

  def with_lock
    member_id = @request ? @request.member_id : @member.id
    key = "checkout_request_lock/#{member_id}/#{@tool.id}"
    token = SecureRandom.uuid
    acquired = REDIS.set(key, token, nx: true, ex: 30)
    reject!("This checkout is being updated. Please try again in a moment.") unless acquired
    yield
  ensure
    if acquired
      begin
        REDIS.eval("if redis.call('get', KEYS[1]) == ARGV[1] then return redis.call('del', KEYS[1]) else return 0 end",
          keys: [key], argv: [token])
      rescue Redis::BaseError => error
        Rails.logger.warn("[SlackCheckout] lock release failed: #{error.class}")
      end
    end
  end

  def notify
    yield
  rescue => error
    Service::ErrorReporter.notify(error, context: { phase: "checkout modal notification" })
  end

  def build
    options = { member: @member, shop: @shop, metadata: @metadata, tool: @tool,
      request: @request, checkout: @checkout, alert: @message }
    case step
    when "request_tools"
      options[:tools] = query.requestable_tools
    when "requests"
      ids = query.open_requests.pluck(:id) | query.open_requests(for_approval: true).pluck(:id)
      enabled = Tool.where(shop_id: @shop.id, :disabled.ne => true, :open.ne => true)
      enabled = enabled.where(allow_pending: true) if @member.status == "pending"
      enabled_ids = enabled.pluck(:id)
      options[:requests] = ToolCheckoutRequest.where(status: "open", :id.in => ids, :tool_id.in => enabled_ids)
        .order_by(request_date: :asc, id: :asc).includes(:member, :tool).to_a
    when "active"
      enabled = Tool.where(shop_id: @shop.id, :disabled.ne => true, :open.ne => true)
      enabled = enabled.where(allow_pending: true) if @member.status == "pending"
      options[:checkouts] = query.active_checkouts.where(:tool_id.in => enabled.pluck(:id)).includes(:tool).to_a
    when "request_detail"
      options[:can_approve] = can_approve?(@tool)
    end
    SlackCheckoutModal.new(**options).build
  end
end
