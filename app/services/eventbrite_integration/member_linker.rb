module EventbriteIntegration
  class MemberLinker
    def self.link(attendee)
      Lease.with("EventbriteAttendee:#{attendee.organization_id}:#{attendee.eventbrite_id}") do |check|
        attendee.reload
        check.call
        link_current(attendee)
      end
    end

    def self.link_current(attendee)
      email = attendee.email.to_s.strip.downcase
      if attendee.member_id
        member = Member.where(id: attendee.member_id).first
        attendee.set(link_conflict: member.nil? || member.email != email)
      elsif email.present? && (member = Member.where(email: email).first)
        EventbriteAttendee.where(id: attendee.id, member_id: nil, email: email).update_all(
          member_id: member.id, matched_email: email, linked_at: Time.current, link_conflict: false)
      end
    end

    def self.reconcile(member)
      marker = member.eventbrite_link_pending_at
      EventbriteAttendee.or({ email: member.email }, { member_id: member.id }).each { |attendee| link(attendee) }
      Member.unscoped.where(id: member.id, eventbrite_link_pending_at: marker).update_all(eventbrite_link_pending_at: nil)
    end
  end
end
