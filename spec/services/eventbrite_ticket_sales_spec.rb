require 'rails_helper'

RSpec.describe EventbriteIntegration::TicketSales do
  let(:now) { Time.utc(2026, 11, 16, 12) }
  let(:first_sale) { now + 1.day }
  let(:ticket) { { 'id' => 'general', 'name' => 'General admission', 'quantity_total' => 10, 'quantity_sold' => 0, 'sales_start' => first_sale.iso8601 } }

  def snapshot(classes, tiers = [], remaining: 10)
    described_class.snapshot(classes, tiers, remaining: remaining, now: now)
  end

  it 'selects the earliest future sale across all ticket classes' do
    later = ticket.merge('id' => 'later', 'sales_start' => (first_sale + 1.day).iso8601)
    expect(snapshot([later, ticket])[:ticket_sales_start_at]).to eq(first_sale)
  end

  it 'does not announce a future sale when another ticket is already on sale' do
    [nil, (now - 1.hour).iso8601, now.iso8601].each do |start|
      current = ticket.merge('id' => 'current', 'sales_start' => start, 'on_sale_status' => 'AVAILABLE')
      expect(snapshot([ticket, current])[:ticket_sales_start_at]).to be_nil
    end
  end

  it 'ignores sold-out, expired, empty and add-on classes when finding the next sale' do
    ignored = [
      ticket.merge('id' => 'sold-out', 'on_sale_status' => 'SOLD_OUT', 'sales_start' => nil),
      ticket.merge('id' => 'expired', 'sales_start' => nil, 'sales_end' => now.iso8601),
      ticket.merge('id' => 'empty', 'quantity_sold' => 10, 'sales_start' => nil),
      ticket.merge('id' => 'add-on', 'inventory_tier_id' => 'extra', 'sales_start' => nil)
    ]
    expect(snapshot(ignored + [ticket], [{ 'id' => 'extra', 'count_against_event_capacity' => false }])[:ticket_sales_start_at]).to eq(first_sale)
  end

  it 'does not promise a date when event or shared-pool capacity is exhausted' do
    expect(snapshot([ticket], remaining: 0)[:ticket_sales_start_at]).to be_nil
    pool = { 'id' => 'pool', 'quantity_total' => 5, 'quantity_sold' => 5 }
    expect(snapshot([ticket.merge('inventory_tier_id' => 'pool')], [pool])[:ticket_sales_start_at]).to be_nil
  end

  it 'does not treat an unresolved sell-out dependency as a scheduled opening' do
    dependent = ticket.merge('id' => 'next', 'sales_start_after' => 'general', 'sales_start' => (now + 1.hour).iso8601, 'on_sale_status' => 'AVAILABLE')
    expect(snapshot([dependent, ticket])[:ticket_sales_start_at]).to eq(first_sale)
    expect(snapshot([dependent])[:ticket_sales_start_at]).to be_nil
  end

  it 'uses the scheduled opening after a predecessor has sold out' do
    sold_out = ticket.merge('quantity_sold' => 10)
    next_class = ticket.merge('id' => 'next', 'sales_start_after' => 'general')
    expect(snapshot([sold_out, next_class])[:ticket_sales_start_at]).to eq(first_sale)
  end

  it 'keeps unknown or malformed sale dates from producing a misleading notice' do
    expect(snapshot([ticket.merge('sales_start' => 'invalid')])[:ticket_sales_start_at]).to be_nil
    expect(snapshot([])[:ticket_sales_start_at]).to be_nil
    expect(snapshot([ticket.merge('inventory_tier_id' => 'missing')])[:ticket_sales_start_at]).to be_nil
    expect(snapshot([ticket.merge('sales_end' => (first_sale - 1.hour).iso8601)])[:ticket_sales_start_at]).to be_nil
  end

  it 'detects member pricing in names or descriptions without requiring tickets to be on sale' do
    expect(snapshot([ticket.merge('name' => 'MEMBER admission')])[:has_member_ticket_class]).to be(true)
    expect(snapshot([ticket.merge('description' => '<p>Members receive a discount.</p>')])[:has_member_ticket_class]).to be(true)
    expect(snapshot([ticket])[:has_member_ticket_class]).to be(false)
    expect(snapshot([])[:has_member_ticket_class]).to be(false)
  end
end
