module FixTicketBounty
  extend ActiveSupport::Concern
  def claim!(member)
    return super unless ticket_id
    raise Error::Forbidden.new unless member.fully_active_unexpired?
    ticket = FixTicket.find(ticket_id)
    result = nil
    FixTicketService.transaction(ticket.reporter_id) do
      reload
      ticket.reload
      raise Error::Forbidden.new unless ticket.active?
      raise Error::Forbidden.new('Required tool checkouts are missing') unless missing_prerequisite_tool_ids(member).empty?
      result = super
      previous = ticket.assignee_ids
      ticket.bounty_assignee_ids = (ticket.bounty_assignee_ids + [member.id]).uniq
      ticket.assignee_ids = (ticket.manual_assignee_ids + ticket.bounty_assignee_ids).uniq
      ticket.save!
      FixTicketService.event!(ticket, member, 'assigned', changes: { 'assignees' => [FixTicketService.names(previous), FixTicketService.names(ticket.assignee_ids)] }, added: [member.id] - previous)
    end
    FixTicketService.enqueue(ticket)
    result
  end
  def release!(member, reason)
    return super unless ticket_id
    release_ticket_claim(member) { super }
  end
  def reject_pending!(member, reason)
    return super unless ticket_id
    release_ticket_claim(member) { super }
  end
  def cancel!
    return super unless ticket_id
    ticket = FixTicket.find(ticket_id)
    FixTicketService.transaction(ticket.reporter_id) do
      reload
      if %w[claimed pending].include?(status)
        raise Error::Forbidden.new('Release or reject the linked bounty claim before cancelling it')
      end
      super
    end
  end
  private
  def release_ticket_claim(actor)
    ticket = FixTicket.find(ticket_id)
    FixTicketService.transaction(ticket.reporter_id) do
      reload
      former = claimed_by_id
      yield
      ticket.reload
      previous = ticket.assignee_ids
      ticket.bounty_assignee_ids -= [former]
      ticket.assignee_ids = (ticket.manual_assignee_ids + ticket.bounty_assignee_ids).uniq
      ticket.save!
      update!(status: 'cancelled') unless ticket.active?
      FixTicketService.event!(ticket, actor, 'assigned', changes: { 'assignees' => [FixTicketService.names(previous), FixTicketService.names(ticket.assignee_ids)] })
    end
    FixTicketService.enqueue(ticket)
    self
  end
end
