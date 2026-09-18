class SlackCheckoutModal
  CALLBACK_ID = "checkout_modal".freeze
  MENU = "checkout_menu".freeze
  SHOP = "checkout_shop".freeze
  TOOL = "checkout_tool".freeze
  REQUEST = "checkout_request".freeze
  CHECKOUT = "checkout_checkout".freeze
  NOTE = "checkout_note".freeze
  BACK = "checkout_back".freeze
  EDIT = "checkout_edit_note".freeze
  CANCEL = "checkout_cancel_request".freeze
  APPROVE = "checkout_approve_request".freeze
  CHOICES = [["View my checkouts", "active"], ["Request a checkout", "request_tools"],
             ["View open requests", "requests"]].freeze
  METADATA_KEYS = %w[member_id shop_id response_url slack_user_id step record_id].freeze

  # Integrity-protected context, not an authorization cache. A client cannot
  # replace the shop or workflow step; the workflow still reloads every record.
  def self.encode_metadata(metadata)
    Rails.application.message_verifier("slack_checkout_modal").generate(
      metadata.slice(*METADATA_KEYS), purpose: "checkout", expires_in: 1.hour)
  end

  def self.decode_metadata(value)
    Rails.application.message_verifier("slack_checkout_modal").verified(value, purpose: "checkout")
  end

  def self.membership_error(member)
    return "Link your Slack account to a Member Portal account before using /checkout." unless member
    case member.status
    when "pending" then nil
    when "revoked" then "Your membership is revoked. Contact the makerspace before using checkouts."
    when "suspended" then "Your membership is suspended. Contact the makerspace before using checkouts."
    when "inactive" then "Your membership is inactive. Activate it before using checkouts."
    when "activeMember"
      "Your membership has expired. Renew it before using checkouts." unless member.active_unexpired?
    else "Your membership is not eligible for checkouts. Contact the makerspace."
    end
  end

  def self.entry(member:, shop: nil, response_url: nil, slack_user_id:)
    metadata = { "member_id" => member.id.to_s, "shop_id" => shop&.id&.to_s,
      "response_url" => response_url, "slack_user_id" => slack_user_id, "step" => "menu" }.compact
    new(member: member, shop: shop, metadata: metadata).build
  end

  def initialize(member: nil, shop: nil, metadata: {}, tools: [], requests: [], checkouts: [],
                 tool: nil, request: nil, checkout: nil, can_approve: false, alert: nil)
    @member, @shop, @metadata = member, shop, metadata.slice(*METADATA_KEYS)
    @tools, @requests, @checkouts = tools, requests, checkouts
    @tool, @request, @checkout, @can_approve, @alert = tool, request, checkout, can_approve, alert
  end

  def build
    @blocks = []
    @submit = nil
    section(@shop.name) if @shop
    section(@alert) if @alert
    case @metadata.fetch("step", "menu")
    when "menu"
      shop_selector unless @shop
      selector(MENU, "What would you like to do?", CHOICES)
    when /\Ashop_(active|request_tools|requests)\z/
      shop_selector
    when "request_tools"
      selector(TOOL, "Tool", @tools.map { |tool| [tool.name, tool.id.to_s] })
    when "request_new"
      section("Request a checkout on #{@tool.name}")
      note_input
      @submit = "Request"
    when "requests"
      selector(REQUEST, "Open request", @requests.map { |row| ["#{row.tool.name} — #{row.member.fullname}", row.id.to_s] })
    when "request_detail"
      request_details
      buttons = []
      buttons += [["Edit note", EDIT], ["Cancel request", CANCEL]] if @request.member_id == @member.id
      buttons << ["Approve request", APPROVE] if @can_approve
      actions(buttons) if buttons.any?
    when "request_edit"
      request_details
      note_input(@request.note)
      @submit = "Save note"
    when "request_cancel", "request_approve"
      request_details
      @submit = @metadata["step"] == "request_cancel" ? "Cancel request" : "Approve"
      section("Select #{@submit} to confirm.")
    when "active"
      selector(CHECKOUT, "Your active checkout", @checkouts.map { |row| [row.tool.name, row.id.to_s] })
    when "checkout_detail"
      section("#{@tool.name} — checked out #{@checkout.checked_out_at&.to_date}")
      section(@tool.notes) if @tool.notes.present?
    end
    actions([["Go back", BACK]], block_id: "checkout_navigation") unless @metadata["step"] == "menu"
    view = { type: "modal", callback_id: CALLBACK_ID, private_metadata: self.class.encode_metadata(@metadata),
      title: plain("Safety checkouts"), close: plain("Close"), blocks: @blocks }
    view[:submit] = plain(@submit) if @submit
    view
  end

  private

  def plain(text)
    { type: "plain_text", text: text.to_s.first(3000) }
  end

  def section(text)
    @blocks << { type: "section", text: plain(text) }
  end

  def shop_selector
    shops = CheckoutInteractionQuery.new(member: @member).enabled_shops
    selector(SHOP, "Shop", shops.map { |shop| [shop.name, shop.id.to_s] })
  end

  def selector(id, label, choices)
    return section("No #{label.downcase} options are currently available.") if choices.empty?
    if choices.length > 100
      return section("There are more than 100 #{label.downcase} options. Use the Member Portal to view them all.")
    end
    # Navigation selectors must not be input blocks: Slack requires a submit
    # button for any view containing inputs, and these steps only navigate.
    @blocks << { type: "section", block_id: id, text: plain(label),
      accessory: { type: "static_select", action_id: "#{id}_select", placeholder: plain("Select an option"),
        options: choices.map { |name, value| { text: plain(name.to_s.first(75)), value: value } } } }
  end

  def note_input(value = nil)
    element = { type: "plain_text_input", action_id: NOTE, max_length: 128 }
    element[:initial_value] = value if value.present?
    @blocks << { type: "input", block_id: NOTE, optional: true, label: plain("Note"), element: element }
  end

  def request_details
    section("#{@request.tool.name} — #{@request.member.fullname}")
    section(@request.note) if @request.note.present?
  end

  def actions(buttons, block_id: "checkout_actions")
    @blocks << { type: "actions", block_id: block_id,
      elements: buttons.map { |label, id| { type: "button", action_id: id, text: plain(label), value: id } } }
  end
end
