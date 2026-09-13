class FixBountySerializer < VolunteerTaskSerializer
  attribute :capabilities do
    ticket = FixTicket.where(id: object.ticket_id).first if object.ticket_id
    {
      canClaim: !!(scope&.fully_active_unexpired? && object.status == 'available' &&
        object.missing_prerequisite_tool_ids(scope).empty? && (!object.ticket_id || (ticket&.active? && ticket.reporter_id != scope.id))),
      canSubmitCompletion: !!(scope && object.status == 'claimed' && object.claimed_by_id == scope.id)
    }
  end
end
