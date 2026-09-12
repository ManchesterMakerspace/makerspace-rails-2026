class FixTicketPolicy
  attr_reader :member, :ticket
  def initialize(member, ticket = nil)
    @member, @ticket = member, ticket
  end
  def global? = member && %w[admin board_member].include?(member.role)
  def current? = !!member&.fully_active_unexpired?
  def approver
    @approver ||= member&.valid_for_checkout_request? && CheckoutApprover.where(member_id: member.id).first
  end
  def staff?
    return false unless member && ticket
    global? || member.manages_shop?(ticket.shop_id) ||
      (approver && (ticket.tool ? approver.can_approve_tool?(ticket.tool) : approver.can_approve_for_shop?(ticket.shop_id)))
  end
  def reporter? = member && ticket && ticket.reporter_id == member.id
  def assigned? = member && ticket && ticket.assignee_ids.map(&:to_s).include?(member.id.to_s)
  def read? = !!(staff? || reporter? || assigned? || (current? && ticket&.public_read_only))
  def note? = !!(staff? || reporter? || assigned?)
  def change_status? = !!(staff? || assigned?)
  def bounty? = !!(global? || (member && ticket && member.manages_shop?(ticket.shop_id)))
  def capabilities
    { canRead: read?, canAddNote: note?, canChangeStatus: change_status?, canManage: !!staff?,
      canManageVisibility: !!staff? && !ticket.public_locked?, publicLocked: !!ticket.public_locked?,
      canWithdraw: !!reporter? && ticket.active?, canUnassign: !!assigned?, canCreateBounty: bounty? && ticket.active? && ticket.bounty_id.nil?,
      canNominateReward: bounty? && !reporter? && ticket.reward_id.nil?, canReviewReward: bounty? && ticket.reward_id.present? && !reporter? && VolunteerCredit.where(id: ticket.reward_id, status: 'pending', :issued_by_id.ne => member.id).exists?, canReveal: member&.role == 'admin' }
  end
  def scope(mode = 'all')
    raise Error::Forbidden.new unless member
    return FixTicket.where(reporter_id: member.id) if mode == 'mine'
    return FixTicket.where(assignee_ids: member.id) if mode == 'assigned'
    return current? ? FixTicket.where(public_read_only: true) : FixTicket.none if mode == 'public'
    return FixTicket.all if global?
    shops = member.role == 'resource_manager' ? Array(member.resource_manager_shop_ids) : []
    rules = [{ :shop_id.in => shops }]
    if approver
      rules << { :shop_id.in => Array(approver.shop_ids) }
      rules << { :tool_id.in => Array(approver.tool_ids) }
    end
    unless mode == 'queue'
      rules += [{ reporter_id: member.id }, { assignee_ids: member.id }]
      rules << { public_read_only: true } if current?
    end
    FixTicket.any_of(*rules)
  end
end
