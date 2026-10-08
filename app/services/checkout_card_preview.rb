# What an approver sees after tapping a member's fob while checking them out on a
# tool: who the fob belongs to and whether they can be checked out on it. Only
# the fields needed to confirm the right person are returned; card internals
# (card id, version, release state) are never exposed here.
module CheckoutCardPreview
  SELF_CHECKOUT_ERROR = "You cannot check yourself out; ask another approver.".freeze

  def self.build(member:, tool:, actor: nil)
    # An existing open request is not a reason to refuse the checkout; approving
    # closes it, so it is ignored here as it is in the Slack approval flow.
    error = ToolCheckoutRequestEligibility.new(member: member, tool: tool, open_request_tool_ids: []).error
    error = SELF_CHECKOUT_ERROR if actor && actor.id == member.id
    held = ToolCheckout.where(member_id: member.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
    missing = Tool.where(:id.in => Array(tool.prerequisite_ids).map(&:to_s) - held).pluck(:name)
    { memberId: member.id.to_s, name: member.fullname, status: member.status,
      expirationTime: member.expirationTime, eligible: error.nil?, error: error,
      unmetPrerequisites: missing }
  end
end
