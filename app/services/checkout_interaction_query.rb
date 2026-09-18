# Short-lived lookup data for one portal response or Slack interaction.
class CheckoutInteractionQuery
  COLLATION = { locale: "en", strength: 2 }.freeze

  def initialize(member:, shop: nil)
    @member, @shop = member, shop
  end

  def enabled_shops
    Shop.where(:disabled.ne => true).collation(COLLATION).order_by(name: :asc, id: :asc)
  end

  def requestable_tools
    candidates = tools.where(:disabled.ne => true, :open.ne => true)
      .collation(COLLATION).order_by(name: :asc, id: :asc).includes(:shop).to_a
    checkouts = ToolCheckout.where(member_id: @member.id).pluck(:tool_id, :revoked_at)
    existing_ids = checkouts.map { |id, _| id.to_s }.to_set
    active_ids = checkouts.filter_map { |id, revoked| id.to_s if revoked.nil? }.to_set
    request_ids = ToolCheckoutRequest.where(member_id: @member.id, status: "open").pluck(:tool_id).map(&:to_s).to_set
    candidates.select do |tool|
      ToolCheckoutRequestEligibility.new(member: @member, tool: tool,
        checkout_tool_ids: existing_ids, active_checkout_tool_ids: active_ids,
        open_request_tool_ids: request_ids).eligible?
    end
  end

  def active_checkouts
    ToolCheckout.where(member_id: @member.id, revoked_at: nil, :tool_id.in => tools.pluck(:id))
  end

  # Personal lists and approval queues are distinct authorization contexts.
  def open_requests(for_approval: false)
    visible_tools = for_approval ? approvable_tools : tools.where(:disabled.ne => true)
    tool_rows = visible_tools.pluck(:id, :allow_pending)
    members = for_approval ? Member.all : Member.where(id: @member.id)
    active_ids = members.where(status: "activeMember", :expirationTime.gt => Time.now.to_i * 1000).pluck(:id)
    pending_ids = members.where(status: "pending").pluck(:id)
    requests = ToolCheckoutRequest.where(status: "open", :tool_id.in => tool_rows.map(&:first))
    requests = requests.where(member_id: @member.id) unless for_approval
    requests.any_of(
      { :member_id.in => active_ids },
      { :member_id.in => pending_ids, :tool_id.in => tool_rows.filter_map { |id, pending| id if pending } }
    ).order_by(request_date: :asc, id: :asc).includes(:member, tool: :shop)
  end

  private

  def tools
    @shop ? Tool.where(shop_id: @shop.id) : Tool.all
  end

  def approvable_tools
    return tools if @member.role.in?(%w[admin board_member])

    managed_ids = @member.role == "resource_manager" ? Array(@member.resource_manager_shop_ids) : []
    approver = CheckoutApprover.find_by(member_id: @member.id) if @member.valid_for_checkout_request?
    tools.any_of(
      { :shop_id.in => managed_ids },
      { :shop_id.in => Array(approver&.shop_ids), :disabled.ne => true },
      { :id.in => Array(approver&.tool_ids), :disabled.ne => true }
    )
  end
end
