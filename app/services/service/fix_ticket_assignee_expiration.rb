module Service
  # An assignee whose membership expires can no longer act on a ticket (log
  # in, add notes, change status). Rather than let it sit assigned to someone
  # who can't touch it, drop them as an assignee, and if that was the last
  # one, kick the ticket back to Open so it re-enters the general queue.
  class FixTicketAssigneeExpiration
    def self.run!
      processed = 0
      FixTicket.where(:status.in => FixTicket::ACTIVE, :assignee_ids.ne => []).each do |ticket|
        expired_ids = Member.where(:id.in => ticket.assignee_ids).reject(&:active_unexpired?).map(&:id)
        next if expired_ids.empty?

        before_assignee_ids = ticket.assignee_ids.dup
        before_status = ticket.status
        release_expired_bounty_claim(ticket, expired_ids)
        ticket.reload
        FixTicketService.expire_assignees!(ticket: ticket, expired_ids: expired_ids)
        ticket.reload

        field_changes = { "assignee_ids" => [before_assignee_ids, ticket.assignee_ids] }
        field_changes["status"] = [before_status, ticket.status] if before_status != ticket.status
        ::Service::AuditLogger.log(
          log_type: "portal", event_type: "fix_ticket_assignee_expired",
          resource_type: "FixTicket", resource_id: ticket.id,
          field_changes: field_changes,
          message_details: "removed expired assignee(s): #{expired_ids.map(&:to_s).join(', ')}"
        )
        processed += 1
      end
      processed
    end

    def self.release_expired_bounty_claim(ticket, expired_ids)
      bounty = ticket.bounty
      return unless bounty && expired_ids.include?(bounty.claimed_by_id)

      actor = Member.find(ticket.reporter_id)
      reason = 'Claim released because the assignee membership expired'
      if bounty.status == 'claimed'
        bounty.release!(actor, reason)
      elsif bounty.status == 'pending'
        bounty.reject_pending!(actor, reason)
      end
    end
    private_class_method :release_expired_bounty_claim
  end
end
