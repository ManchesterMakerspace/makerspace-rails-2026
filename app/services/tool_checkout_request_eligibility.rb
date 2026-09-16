class ToolCheckoutRequestEligibility
  attr_reader :member, :tool

  def self.eligible_tools(member:, shop: nil)
    scope = Tool.where(:disabled.ne => true)
    scope = scope.where(shop_id: shop.id) if shop
    scope.order_by(name: :asc).select { |tool| new(member: member, tool: tool).eligible? }
  end

  def initialize(member:, tool:)
    @member = member
    @tool = tool
  end

  def eligible?
    error.nil?
  end

  def membership_ineligible?
    !tool.open && !tool.disabled? && tool.shop.present? && !tool.shop.disabled? && !membership_eligible?
  end

  def error
    return "No checkout required" if tool.open
    return "Tool unavailable" if tool.disabled? || tool.shop.nil? || tool.shop.disabled?
    return membership_error unless membership_eligible?
    return "Complete all prerequisite checkouts before requesting this tool" unless prerequisites_met?
    return "A checkout record already exists for this tool" if checkout_exists?
    return "An open request already exists for this tool" if open_request_exists?
  end

  private

  def membership_eligible?
    member.status == "pending" ? tool.allow_pending : member.status == "activeMember" && member.active_unexpired?
  end

  def membership_error
    "Your membership must first be activated and you must complete your Orientation checkout before requesting this Safety Checkout"
  end

  def prerequisites_met?
    required_ids = Array(tool.prerequisite_ids).map(&:to_s).reject(&:blank?).uniq
    return true if required_ids.empty?

    checkout_ids = ToolCheckout.where(
      member_id: member.id,
      :tool_id.in => required_ids,
      revoked_at: nil
    ).pluck(:tool_id).map(&:to_s).uniq
    (required_ids - checkout_ids).empty?
  end

  def checkout_exists?
    ToolCheckout.where(member_id: member.id, tool_id: tool.id).exists?
  end

  def open_request_exists?
    ToolCheckoutRequest.where(member_id: member.id, tool_id: tool.id, status: "open").exists?
  end
end
