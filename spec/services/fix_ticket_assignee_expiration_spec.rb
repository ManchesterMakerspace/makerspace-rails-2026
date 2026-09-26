require "rails_helper"

RSpec.describe Service::FixTicketAssigneeExpiration, requires_transactions: true do
  let(:active_member) { create(:member, :current) }
  let(:expired_member) { create(:member, :expired) }

  describe ".run!" do
    it "unassigns an expired assignee and reverts to open when they were the only one" do
      ticket = create(:fix_ticket, status: "in_progress", assignee_ids: [expired_member.id],
        manual_assignee_ids: [expired_member.id])

      described_class.run!
      ticket.reload

      expect(ticket.assignee_ids).to be_empty
      expect(ticket.manual_assignee_ids).to be_empty
      expect(ticket.status).to eq("open")
      expect(ticket.revision).to eq(1)
      event = FixTicketEvent.where(ticket_id: ticket.id, kind: 'assigned').first
      expect(event).to be_present
      expect(event.revision).to eq(ticket.revision)
      expect(event.field_changes['status']).to eq(['in_progress', 'open'])
    end

    it "keeps the ticket's status when another active assignee remains" do
      ticket = create(:fix_ticket, status: "in_progress",
        assignee_ids: [expired_member.id, active_member.id],
        manual_assignee_ids: [expired_member.id, active_member.id])

      described_class.run!
      ticket.reload

      expect(ticket.assignee_ids).to eq([active_member.id])
      expect(ticket.manual_assignee_ids).to eq([active_member.id])
      expect(ticket.status).to eq("in_progress")
    end

    it "leaves tickets with only active assignees untouched" do
      ticket = create(:fix_ticket, status: "in_progress", assignee_ids: [active_member.id])

      expect { described_class.run! }.not_to change { ticket.reload.attributes }
    end

    it "ignores terminal tickets even with an expired assignee" do
      ticket = create(:fix_ticket, status: "resolved", assignee_ids: [expired_member.id])

      expect { described_class.run! }.not_to change { ticket.reload.attributes }
    end

    it "records an audit log entry for the change" do
      ticket = create(:fix_ticket, status: "in_progress", assignee_ids: [expired_member.id])

      described_class.run!

      log = AuditLog.where(resource_type: "FixTicket", event_type: "fix_ticket_assignee_expired").first
      expect(log).to be_present
      expect(log.field_changes["status"]).to eq(["in_progress", "open"])
    end

    it "releases an expired assignee's linked bounty claim" do
      reporter = create(:member, :current)
      ticket = create(:fix_ticket, reporter_id: reporter.id, status: 'in_progress',
        assignee_ids: [expired_member.id], bounty_assignee_ids: [expired_member.id])
      bounty = VolunteerTask.create!(title: 'Repair', description: 'Fix it', credit_value: 1,
        created_by_id: reporter.id, ticket_id: ticket.id, status: 'claimed',
        claimed_by_id: expired_member.id, claimed_at: Time.current)
      ticket.set(bounty_id: bounty.id)
      allow_any_instance_of(VolunteerTask).to receive(:notify_member_task_released)
      allow_any_instance_of(VolunteerTask).to receive(:enqueue_volunteer_canvas_sync)

      described_class.run!

      expect(bounty.reload).to have_attributes(status: 'available', claimed_by_id: nil)
      expect(ticket.reload).to have_attributes(status: 'open', assignee_ids: [], bounty_assignee_ids: [])
      event = FixTicketEvent.where(ticket_id: ticket.id, kind: 'assigned').first
      expect(event.field_changes['status']).to eq(['in_progress', 'open'])
      expect(event.revision).to eq(ticket.revision)
    end

    it "returns the number of tickets it changed" do
      create(:fix_ticket, status: "in_progress", assignee_ids: [expired_member.id])
      create(:fix_ticket, status: "in_progress", assignee_ids: [active_member.id])

      expect(described_class.run!).to eq(1)
    end
  end
end
