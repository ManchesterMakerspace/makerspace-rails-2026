class FixBountySerializer < VolunteerTaskSerializer
  attribute :capabilities do
    ticket = FixTicket.where(id: object.ticket_id).first if object.ticket_id
    {
      canClaim: !!(scope&.fully_active_unexpired? && object.status == 'available' &&
        (object.ticket_id ? (object.missing_prerequisite_tool_ids(scope).empty? && ticket&.active? && ticket.reporter_id != scope.id) : object.eligible_for?(scope))),
      canSubmitCompletion: !!(scope && object.status == 'claimed' && object.claimed_by_id == scope.id)
    }
  end
end
