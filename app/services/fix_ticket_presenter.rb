class FixTicketPresenter
  def self.member_label(id, ticket)
    id.to_s == ticket.reporter_id.to_s ? 'Reporter' : (Member.where(id: id).first&.fullname || 'Former member')
  end
  def self.ticket(ticket, member, detail: false)
    policy = FixTicketPolicy.new(member, ticket)
    raise Error::NotFound.new unless policy.read?
    result = { id: ticket.id.to_s, reference: ticket.id.to_s, title: ticket.title, description: ticket.description,
      category: ticket.category, status: ticket.status, confirmation: ticket.confirmation,
      priority: ticket.priority, submittedPriority: ticket.submitted_priority, shopId: ticket.shop_id&.to_s,
      shopName: ticket.shop&.name, toolId: ticket.tool_id&.to_s, toolName: ticket.tool&.name,
      toolHidden: !!ticket.tool&.disabled, outOfService: !!ticket.tool&.out_of_service, uncataloguedTool: ticket.uncatalogued_tool,
      publicReadOnly: ticket.public_read_only, iBrokeIt: ticket.i_broke_it, iCanFixIt: ticket.i_can_fix_it,
      assignees: ticket.assignee_ids.map { |id| { id: id.to_s, name: member_label(id, ticket) } },
      announceToSlack: ticket.announce_to_slack, announcementNote: ticket.announcement_note,
      bountyId: ticket.bounty_id&.to_s, bountyUrl: ticket.bounty_id ? "/volunteer/tasks/#{ticket.bounty_id}" : nil,
      rewardStatus: ticket.reward_id ? VolunteerCredit.where(id: ticket.reward_id).first&.status : nil,
      revision: ticket.revision, createdAt: ticket.created_at, updatedAt: ticket.updated_at,
      capabilities: policy.capabilities }
    # Assignments must never expose which member is the submitter. If the reporter
    # volunteers, display their ordinary assignee identity without labeling the link.
    result[:assignees] = ticket.assignee_ids.map { |id| { id: id.to_s, name: Member.where(id: id).first&.fullname || 'Former member' } }
    if detail
      result[:events] = FixTicketEvent.where(ticket_id: ticket.id).order_by(revision: :asc).map do |event|
        { id: event.id.to_s, kind: event.kind, note: event.note, changes: event.field_changes,
          actor: member_label(event.actor_id, ticket), createdAt: event.created_at }
      end
      result[:deliveryFailed] = !!policy.staff? && FixTicketEvent.where(ticket_id: ticket.id, :delivery_error.ne => nil).exists?
    end
    result
  end
end
