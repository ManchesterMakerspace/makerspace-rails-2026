require 'rails_helper'

RSpec.describe 'Member Home volunteer recommendations' do
  let(:member) { create(:member, :current) }
  subject(:home) { MemberHome.new(member) }

  before { allow(REDIS).to receive(:set).and_return(true) }

  def task(**attributes)
    VolunteerTask.create!({ title: 'Help in the shop', description: 'Organize supplies' }.merge(attributes))
  end

  def event(**attributes)
    VolunteerEvent.create!({ title: 'Help at the open house', event_date: VolunteerTask.business_date + 1.day }.merge(attributes))
  end

  def ids
    home.available_volunteer_opportunities.pluck(:id)
  end

  %w[pending inactive nonMember revoked suspended expired].each do |status|
    it "omits recommendations for #{status} members" do
      task
      event
      member.set(status: status)
      expect(home.available_volunteer_opportunities).to be_empty
    end
  end

  it 'ranks the combined eligible pool by descending credits before limiting to five' do
    6.times { task(status: 'cancelled') }
    candidates = 6.times.map { |n| task(title: "Task #{n}", credit_value: 1.0 + n / 10.0) } +
      6.times.map { |n| event(title: "Event #{n}", credit_value: 1.0 + n / 10.0) }
    first = home.available_volunteer_opportunities
    second = home.available_volunteer_opportunities
    expect(first.length).to eq(5)
    expect(first.pluck(:id).uniq.length).to eq(5)
    expect(first.pluck(:id) - candidates.map { |row| row.id.to_s }).to be_empty
    expect(first.pluck(:kind).uniq).to contain_exactly('task', 'event')
    expect(first.pluck(:creditValue)).to eq([1.5, 1.5, 1.4, 1.4, 1.3])
    expect(first).to eq(second)
  end

  it 'puts eligible weekday tasks for today first and mixes other tasks and events in the remaining ranked places' do
    today = VolunteerTask.business_date
    task(title: 'Wrong weekday', status: 'reusable', day_of_week: (today.wday + 1) % 7, credit_value: 2)
    unavailable = task(title: 'Already claimed weekday task', status: 'reusable', day_of_week: today.wday, credit_value: 2)
    task(parent_task_id: unavailable.id, claimed_by_id: member.id, status: 'completed')
    priority_low = task(title: 'Today lower credit', status: 'repeatable', day_of_week: today.wday, credit_value: 0.5)
    priority_high = task(title: 'Today higher credit', status: 'reusable', day_of_week: today.wday, credit_value: 1)
    other_task = task(title: 'Any day task', credit_value: 2)
    other_event = event(title: 'Any day event', credit_value: 1.5)
    other_small = task(title: 'Any day small task', credit_value: 0.5)
    expect(ids).to eq([priority_high, priority_low, other_task, other_event, other_small].map { |row| row.id.to_s })
    expect(ids.uniq).to eq(ids)
  end

  it 'uses title then ID to order equal-credit opportunities deterministically' do
    zebra = task(title: 'Zebra')
    alpha = event(title: 'alpha')
    beta_first = task(title: 'Beta')
    beta_last = task(title: 'Beta')
    expect(ids).to eq([alpha, beta_first, beta_last, zebra].map { |row| row.id.to_s })
  end

  it 'returns up to five from each pool without spilling additional weekday tasks into the other pool' do
    today = VolunteerTask.business_date
    weekday_tasks = 6.times.map do |i|
      task(title: "Today #{i}", status: 'reusable', day_of_week: today.wday, credit_value: 1 + i / 10.0)
    end
    other_events = 6.times.map { |i| event(title: "Event #{i}", credit_value: 1 + i / 10.0) }
    expected = weekday_tasks.reverse.first(5) + other_events.reverse.first(5)
    expect(ids).to eq(expected.map { |row| row.id.to_s })
    expect(ids.length).to eq(10)
    expect(ids).not_to include(weekday_tasks.first.id.to_s)
  end

  it 'uses the Eastern weekday around a UTC date boundary' do
    travel_to(Time.utc(2026, 11, 24, 2)) do
      today = task(title: 'Monday task', status: 'reusable', day_of_week: 1)
      task(title: 'Tuesday task', status: 'reusable', day_of_week: 2)
      expect(ids).to eq([today.id.to_s])
    end
  end

  it 'uses only claimable parent tasks and respects recurring cooldowns' do
    available = task
    reusable = task(status: 'reusable')
    repeatable = task(status: 'repeatable')
    recurring = task(status: 'recurring', days: 7, next_available: Date.today)
    task(status: 'recurring', days: 7, next_available: Date.tomorrow)
    %w[claimed pending completed cancelled denied].each { |status| task(status: status) }
    task(parent_task_id: repeatable.id)
    expect(ids).to contain_exactly(*[available, reusable, repeatable, recurring].map { |row| row.id.to_s })
  end

  it 'excludes reusable claims forever and repeatable claims only while in progress' do
    reusable = task(status: 'reusable')
    repeatable = task(status: 'repeatable')
    task(parent_task_id: reusable.id, claimed_by_id: member.id, status: 'completed')
    claim = task(parent_task_id: repeatable.id, claimed_by_id: member.id, status: 'claimed')
    expect(ids).to be_empty
    claim.set(status: 'pending')
    expect(ids).to be_empty
    claim.set(status: 'completed')
    expect(ids).to eq([repeatable.id.to_s])
  end

  it 'allows multi-use tasks after denied claims and ignores another member claims' do
    reusable = task(status: 'reusable')
    task(parent_task_id: reusable.id, claimed_by_id: member.id, status: 'denied')
    task(parent_task_id: reusable.id, claimed_by_id: create(:member).id, status: 'completed')
    expect(ids).to eq([reusable.id.to_s])
  end

  it 'includes only future open events the member has not already joined' do
    future = event
    event(event_date: VolunteerTask.business_date)
    event(event_date: VolunteerTask.business_date - 1.day)
    event(event_date: nil)
    event(status: 'closed')
    event(attendee_ids: [member.id])
    event(attendee_ids: [member.id.to_s])
    expect(home.available_volunteer_opportunities).to contain_exactly(
      id: future.id.to_s, kind: 'event', title: future.title, description: nil,
      creditValue: 1.0, shopName: nil, eventDate: (VolunteerTask.business_date + 1.day).iso8601
    )
  end

  it 'requires all task and event prerequisites, including revoked or missing checkouts' do
    shop = create(:shop)
    first = create(:tool, shop: shop)
    second = create(:tool, shop: shop)
    required_ids = [first.id.to_s, second.id.to_s]
    restricted = task(shop_id: shop.id, prerequisite_tool_ids: required_ids)
    restricted_event = event(shop_id: shop.id, prerequisite_tool_ids: required_ids)
    create(:tool_checkout, member: member, tool: first)
    expect(ids).to be_empty
    checkout = create(:tool_checkout, member: member, tool: second, revoked_at: Time.current)
    expect(ids).to be_empty
    checkout.set(revoked_at: nil)
    expect(ids).to contain_exactly(restricted.id.to_s, restricted_event.id.to_s)
    second.destroy!
    checkout.destroy!
    expect(ids).to be_empty
  end

  it 'preserves hidden-shop redaction without bypassing its prerequisite checks' do
    shop = create(:shop, disabled: true)
    tool = create(:tool, shop: shop, disabled: true)
    task(shop_id: shop.id, prerequisite_tool_ids: [tool.id.to_s])
    expect(ids).to be_empty
    create(:tool_checkout, member: member, tool: tool)
    expect(home.available_volunteer_opportunities.first[:shopName]).to be_nil
  end

  it 'uses linked repair bounty eligibility for reporters, resolved tickets and expired members' do
    ticket = create(:fix_ticket, reporter_id: member.id)
    task(ticket_id: ticket.id)
    expect(ids).to be_empty
    ticket = create(:fix_ticket)
    bounty = task(ticket_id: ticket.id)
    expect(ids).to eq([bounty.id.to_s])
    member.set(expirationTime: 1.day.ago.to_i * 1000)
    expect(ids).to be_empty
    member.set(expirationTime: 1.day.from_now.to_i * 1000)
    ticket.set(status: 'resolved')
    expect(ids).to be_empty
  end

  it 'does not claim, check in, or enqueue notifications while reading recommendations' do
    member
    task
    event
    expect(VolunteerTask).not_to receive(:create!)
    expect(VolunteerSlackCanvasSyncJob).not_to receive(:perform_later)
    expect(Service::SlackConnector).not_to receive(:client)
    expect(Service::SlackConnector).not_to receive(:send_slack_message)
    expect(ids.length).to eq(2)
    expect(VolunteerTask.first.status).to eq('available')
    expect(VolunteerEvent.first.attendee_ids).to be_empty
  end
end
