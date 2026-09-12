require 'rails_helper'

RSpec.describe FixTicketService do
  def member(role: 'member', status: 'activeMember', expiry: 30.days.from_now.to_i * 1000)
    id = BSON::ObjectId.new
    Member.collection.insert_one(_id: id, firstname: 'Test', lastname: id.to_s, email: "#{id}@example.com", role: role, status: status, expirationTime: expiry, member_contract_signed_date: Date.current)
    Member.find(id)
  end
  def report(actor, **attrs)
    described_class.create!(actor: actor, attributes: { title: 'Broken drill', description: 'Motor does not start', category: 'broken', submission_key: SecureRandom.uuid }.merge(attrs))
  end
  let(:reporter) { member }
  let(:admin) { member(role: 'admin') }
  before do
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
  end
  it 'inserts into a collision chain, stopping at a gap and keeping other reporters independent' do
    one = report(reporter, priority: 1)
    two = report(reporter, priority: 2)
    four = report(reporter, priority: 4)
    unrelated = report(member, priority: 1)
    fresh = report(reporter, priority: 1)
    expect([fresh.priority, one.reload.priority, two.reload.priority, four.reload.priority, unrelated.reload.priority]).to eq([1, 2, 3, 4, 1])
  end
  it 'clears priority overflow and rejects manual changes' do
    ten = report(reporter, priority: 10)
    report(reporter, priority: 10)
    expect(ten.reload.priority).to be_nil
    expect { described_class.update!(id: ten.id, actor: admin, attributes: { priority: 3 }) }.to raise_error(Error::UnprocessableEntity)
  end
  it 'enforces cap after downgrade and allows withdrawal from waiting for parts' do
    SystemConfig.set('ticket_open_limit', '1')
    first = report(admin)
    second = report(admin)
    admin.set(role: 'member')
    expect { report(admin) }.to raise_error(Error::UnprocessableEntity)
    first.set(status: 'waiting_for_parts')
    described_class.withdraw!(id: first.id, actor: admin)
    expect { report(admin) }.to raise_error(Error::UnprocessableEntity)
    described_class.withdraw!(id: second.id, actor: admin)
    expect(report(admin)).to be_persisted
  end
  it 'deduplicates a submission without another priority shift' do
    key = SecureRandom.uuid
    first = report(reporter, priority: 1, submission_key: key)
    same = report(reporter, priority: 1, submission_key: key)
    expect(same.id).to eq(first.id)
    expect(FixTicket.count).to eq(1)
  end
  it 'rejects pending and expired submissions' do
    expect { report(member(status: 'pending')) }.to raise_error(Error::Forbidden)
    expect { report(member(expiry: 1.day.ago.to_i * 1000)) }.to raise_error(Error::Forbidden)
  end
  it 'keeps public access read-only and excludes reporter identity' do
    ticket = report(reporter, public_read_only: true)
    viewer = member
    result = FixTicketPresenter.ticket(ticket, viewer, detail: true)
    expect(result.to_json).not_to include(reporter.id.to_s, reporter.fullname)
    expect { described_class.update!(id: ticket.id, actor: viewer, attributes: { note: 'injected' }) }.to raise_error(Error::Forbidden)
    expect { described_class.note!(id: ticket.id, actor: viewer, note: 'injected') }.to raise_error(Error::Forbidden)
    viewer.set(expirationTime: 1.day.ago.to_i * 1000)
    expect(FixTicketPolicy.new(viewer, ticket).read?).to be(false)
  end
  it 'grants assignment rights, retains them after expiry, and removes only assignment rights on self-unassignment' do
    ticket = report(reporter)
    volunteer = member
    described_class.assign!(id: ticket.id, actor: admin, member_ids: [volunteer.id])
    volunteer.set(expirationTime: 1.day.ago.to_i * 1000)
    described_class.note!(id: ticket.id, actor: volunteer, note: 'Looking into it')
    described_class.assign!(id: ticket.id, actor: volunteer, unassign_self: true)
    expect(FixTicketPolicy.new(volunteer, ticket.reload).read?).to be(false)
  end
  it 'requires closure and confirmation notes and reopens without priority' do
    ticket = report(reporter, priority: 1)
    expect { described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'resolved' }) }.to raise_error(Error::UnprocessableEntity)
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'resolved', note: 'Replaced switch' })
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'open', note: 'Failed again' })
    expect(ticket.reload.priority).to be_nil
  end
  it 'advances meaningful timestamps but not delivery bookkeeping' do
    ticket = report(reporter)
    created = ticket.created_at
    travel 1.minute do
      described_class.note!(id: ticket.id, actor: reporter, note: 'More details')
      expect(ticket.reload.updated_at).to be > created
      updated = ticket.updated_at
      ticket.set(slack_ticket_ts: '123.456')
      expect(ticket.reload.updated_at).to eq(updated)
      expect(ticket.created_at).to eq(created)
    end
  end
  it 'filters and sorts before pagination and keeps unspecified priority last in descending order' do
    report(reporter, priority: nil)
    one = report(reporter, priority: 1)
    ten = report(reporter, priority: 10)
    result = FixTicketQuery.call(reporter, { mode: 'mine', direction: 'desc', page_size: 1 })
    expect(result[:total]).to eq(3)
    expect(result[:tickets].first[:id]).to eq(ten.id.to_s)
    expect(FixTicketQuery.call(reporter, { mode: 'mine', priority: '1' })[:tickets].first[:id]).to eq(one.id.to_s)
  end
  it 'publishes a linked bounty atomically and locks public visibility' do
    ticket = report(reporter)
    expect { described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: '' }) }.to raise_error(Mongoid::Errors::Validations)
    expect(ticket.reload.public_read_only).to be(false)
    described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 1 })
    expect(ticket.reload.bounty.ticket_id).to eq(ticket.id)
    expect(ticket.public_read_only).to be(true)
    expect { described_class.update!(id: ticket.id, actor: admin, attributes: { public_read_only: false }) }.to raise_error(Error::UnprocessableEntity)
    described_class.withdraw!(id: ticket.id, actor: reporter)
    expect(ticket.bounty.reload.status).to eq('cancelled')
  end
  it 'serializes concurrent submissions at the cap' do
    SystemConfig.set('ticket_open_limit', '1')
    person = reporter
    gate = Queue.new
    results = 2.times.map do
      Thread.new do
        gate.pop
        begin
          report(Member.find(person.id))
        rescue Error::UnprocessableEntity => error
          error
        end
      end
    end
    2.times { gate << true }
    values = results.map(&:value)
    expect(values.count { |v| v.is_a?(FixTicket) }).to eq(1)
    expect(FixTicket.where(reporter_id: person.id).count).to eq(1)
  end
  it 'requires an independent anonymous reward reviewer and prevents duplicate rewards' do
    ticket = report(reporter)
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'resolved', note: 'Repaired', nominate_reward: true })
    credit_id = ticket.reload.reward_id
    expect { described_class.review_reward!(id: ticket.id, actor: admin, approve: true) }.to raise_error(Error::Forbidden)
    reviewer = member(role: 'admin')
    allow_any_instance_of(VolunteerCredit).to receive(:notify_member_credit_awarded)
    allow_any_instance_of(VolunteerCredit).to receive(:check_discount_threshold!)
    described_class.review_reward!(id: ticket.id, actor: reviewer, approve: true)
    expect(VolunteerCredit.find(credit_id).status).to eq('approved')
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'open', note: 'Regression' })
    described_class.update!(id: ticket.id, actor: admin, attributes: { status: 'resolved', note: 'Repaired again', nominate_reward: true })
    expect(ticket.reload.reward_id).to eq(credit_id)
    expect(FixTicketPresenter.ticket(ticket, reviewer, detail: true).to_json).not_to include(reporter.id.to_s)
  end

  it 'preserves manual assignments when a bounty claim is released after ticket closure' do
    ticket = report(reporter)
    volunteer = member
    described_class.assign!(id: ticket.id, actor: admin, member_ids: [volunteer.id])
    described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 1 })
    task = ticket.reload.bounty
    allow(task).to receive(:enqueue_volunteer_canvas_sync)
    allow(task).to receive(:notify_member_task_released)
    task.claim!(volunteer)
    expect(ticket.reload.bounty_assignee_ids).to include(volunteer.id)
    described_class.assign!(id: ticket.id, actor: admin, member_ids: [volunteer.id])
    described_class.withdraw!(id: ticket.id, actor: reporter)
    expect(task.reload.status).to eq('claimed')
    task.release!(admin, 'Cannot complete')
    expect(task.reload.status).to eq('cancelled')
    expect(ticket.reload.assignee_ids).to include(volunteer.id)
    expect(ticket.bounty_assignee_ids).to be_empty
  end

  it 'restricts report names on creation and editing, including Slack service calls' do
    expect { report(reporter, title: 'Drill <script>') }.to raise_error(Error::UnprocessableEntity)
    expect { report(reporter, uncatalogued_tool: 'Saw @channel') }.to raise_error(Error::UnprocessableEntity)
    ticket = report(reporter, title: 'Drill-2 (bench), 1/4 in.', uncatalogued_tool: 'Drill_press / 2')
    expect { described_class.update!(id: ticket.id, actor: admin, attributes: { title: 'Saw <img>' }) }.to raise_error(Mongoid::Errors::Validations)
    expect { described_class.update!(id: ticket.id, actor: admin, attributes: { uncatalogued_tool: "Saw\nName" }) }.to raise_error(Mongoid::Errors::Validations)
    expect(ticket.reload.title).to eq('Drill-2 (bench), 1/4 in.')
  end

  %w[admin board_member resource_manager].each do |role|
    it "requires actual prerequisite checkouts for a #{role} claiming a ticket bounty" do
      tool = create(:tool, shop: create(:shop))
      ticket = report(reporter, shop_id: tool.shop_id.to_s)
      described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 1, prerequisite_tool_ids: [tool.id.to_s] })
      task = ticket.reload.bounty
      claimant = member(role: role)
      expect(task.eligible_for?(claimant)).to be(true) # Ordinary bounties retain the existing exemption.
      expect { task.claim!(claimant) }.to raise_error(Error::Forbidden)
      expect(task.reload.status).to eq('available')
      expect(ticket.reload.assignee_ids).not_to include(claimant.id)
      create(:tool_checkout, member: claimant, tool: tool)
      task.claim!(claimant)
      expect(task.reload.claimed_by_id).to eq(claimant.id)
      expect(ticket.reload.bounty_assignee_ids).to include(claimant.id)
    end
  end

  it 'does not turn a bounty claimant into a manual assignee when staff edits the effective list' do
    ticket = report(reporter)
    claimant, helper = member, member
    described_class.bounty!(id: ticket.id, actor: admin, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 1 })
    task = ticket.reload.bounty
    allow(task).to receive(:enqueue_volunteer_canvas_sync)
    allow(task).to receive(:notify_member_task_released)
    task.claim!(claimant)
    described_class.assign!(id: ticket.id, actor: admin, member_ids: [claimant.id, helper.id])
    expect(ticket.reload.manual_assignee_ids).to eq([helper.id])
    expect(ticket.bounty_assignee_ids).to eq([claimant.id])
    task.release!(admin, 'Unable to finish')
    expect(ticket.reload.assignee_ids).to eq([helper.id])
    expect(FixTicketPolicy.new(claimant, ticket).note?).to be(false)
    expect(FixTicketPolicy.new(claimant, ticket).change_status?).to be(false)
  end

end
