require "rails_helper"

RSpec.describe ReservationFeeService do
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop, reservable: true, max_reservation_duration_hours: 72) }
  let(:option) { InvoiceOption.create!(name: "Extended use", amount: 10, quantity: 1, resource_class: "fee") }
  let(:day_option) { InvoiceOption.create!(name: "Daily use", amount: 15, quantity: 1, resource_class: "fee") }
  let(:start_at) { (Time.current.in_time_zone(ReservationService::ZONE) + 2.days).beginning_of_day }
  let(:attributes) { { title: "Extended project", shop_id: shop.id, reservation_scope: "shop", tool_ids: [], start_at: start_at, end_at: start_at + 12.hours } }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    shop.update!(duration_fees: [
      { invoice_option_id: option.id.to_s, minimum_hours: 4, maximum_hours: 4, full_day: false },
      { invoice_option_id: day_option.id.to_s, full_day: true }
    ])
  end

  def book(input = attributes)
    quote = ReservationService.preview(member: member, attributes: input)
    ReservationService.create!(member: member, attributes: input.merge(fee_confirmation: quote[:feeConfirmation]))
  end

  it "charges three four-hour units for twelve hours and only the daily fee for a full day" do
    quote = ReservationService.preview(member: member, attributes: attributes)
    expect(quote[:feeTotal]).to eq(30)
    expect(quote[:feeLines].first[:units]).to eq(3)
    daily = ReservationService.preview(member: member, attributes: attributes.merge(full_day: true, end_at: start_at + 1.day))
    expect(daily[:feeTotal]).to eq(15)
    expect(daily[:feeLines].length).to eq(1)
  end

  it "rounds partial billing units up and applies only the longest overlapping rule" do
    shop.update!(duration_fees: shop.duration_fees + [{ invoice_option_id: day_option.id.to_s, minimum_hours: 8, maximum_hours: 8 }])
    quote = ReservationService.preview(member: member, attributes: attributes.merge(end_at: start_at + 12.5.hours))
    expect(quote[:feeLines].length).to eq(1)
    expect(quote[:feeLines].first[:unitHours]).to eq(8)
    expect(quote[:feeTotal]).to eq(30)
  end

  it "requires explicit acceptance of the current price before creating any records" do
    expect { ReservationService.create!(member: member, attributes: attributes) }.to raise_error(Error::UnprocessableEntity, /approve/)
    expect(Reservation.count).to eq(0)
    expect(Invoice.count).to eq(0)
  end

  it "creates an unpaid reservation linked to a fee invoice due four hours before start" do
    reservation = book
    expect(reservation.status).to eq("unpaid")
    expect(reservation.blocking?).to eq(true)
    expect(reservation.fee_invoice).to have_attributes(amount: 30, resource_class: "fee", due_date: start_at - 4.hours)
    expect(reservation.reload.fee_snapshot.first["units"]).to eq(3)
  end

  it "preserves rules and prices on existing reservations after rule and catalog deletion" do
    reservation = book
    shop.update!(duration_fees: [])
    option.destroy
    input = attributes.merge(end_at: start_at + 16.hours)
    quote = ReservationService.preview(member: member, attributes: input, reservation: reservation)
    expect(quote[:feeTotal]).to eq(40)
    expect(reservation.reload.fee_invoice.amount).to eq(30)
    expect(ReservationService.preview(member: member, attributes: attributes)[:feeTotal]).to eq(0)
  end

  it "blocks new charged reservations for overdue fee debt without blocking free reservations" do
    Invoice.create!(member: member, resource_id: member.id.to_s, resource_class: "fee", amount: 5, due_date: 1.hour.ago)
    expect(ReservationService.preview(member: member, attributes: attributes)[:errors]).to include(/overdue/)
    expect(ReservationService.preview(member: member, attributes: attributes.merge(end_at: start_at + 1.hour))[:errors]).not_to include(/overdue/)
  end

  it "requires future midnight boundaries and whole-day resource maximums" do
    shop.update!(reservation_full_day: true)
    expect(ReservationService.preview(member: member, attributes: attributes)[:errors]).to include(/requires full-day/)
    invalid = attributes.merge(full_day: true, start_at: start_at + 1.hour, end_at: start_at + 25.hours)
    expect(ReservationService.preview(member: member, attributes: invalid)[:errors]).to include(/midnight/)
    invalid = attributes.merge(full_day: true, start_at: Time.current.in_time_zone(ReservationService::ZONE).beginning_of_day)
    expect(ReservationService.preview(member: member, attributes: invalid)[:errors]).to include(/future date/)
    shop.max_reservation_duration_hours = 25
    expect(shop).not_to be_valid
  end

  it "counts DST calendar days as one full-day fee and 24 nominal hours" do
    zone = ReservationService::ZONE
    [zone.local(2027, 3, 14), zone.local(2026, 11, 1)].each do |start|
      finish = start.advance(days: 1)
      expect(described_class.duration_hours(start, finish, true)).to eq(24)
      quote = described_class.quote(resources: [shop], start_at: start, end_at: finish, full_day: true)
      expect(described_class.total(quote)).to eq(15)
    end
  end

  it "restores approval state on payment without reviving a cancelled reservation" do
    reservation = book
    invoice = reservation.fee_invoice
    expect {
      invoice.submit_for_settlement(nil, nil, "reservation-payment")
    }.to have_enqueued_job(ReservationInvoiceSyncJob).with(invoice.id.to_s)
    expect {
      ReservationInvoiceSyncJob.perform_now(invoice.id.to_s)
    }.to have_enqueued_job(ReservationFeeNotificationJob).with(reservation.id.to_s)
    expect(reservation.reload.status).to eq("approved")
    reservation.update!(status: "cancelled")
    described_class.reconcile!(reservation)
    expect(reservation.reload.status).to eq("cancelled")
  end

  it "issues the confirmed fee only after RM approval, then approves on payment" do
    shop.update!(reservation_requires_approval: true)
    reservation = book
    expect(reservation.status).to eq("pending")
    expect(reservation.invoice).to be_nil
    expect(Invoice.where(reservation_id: reservation.id.to_s).count).to eq(0)
    expect(described_class.total(reservation.fee_snapshot)).to eq(30)
    expect(ReservationFeeNotificationJob).not_to have_been_enqueued

    preview = ReservationService.preview(member: member, attributes: attributes, reservation: reservation)
    expect(preview[:feeTotal]).to eq(30)

    ReservationService.approve!(reservation: reservation, actor: create(:member, :current))
    expect(reservation.reload.status).to eq("unpaid")
    expect(reservation.fee_invoice).to have_attributes(amount: 30, due_date: start_at - 4.hours)
    expect(ReservationFeeNotificationJob).to have_been_enqueued.with(reservation.id.to_s)
    reservation.fee_invoice.update!(settled_at: Time.current)
    described_class.reconcile!(reservation)
    expect(reservation.reload.status).to eq("approved")
  end

  it "updates the pending quote without an invoice and bills that quote on approval" do
    shop.update!(reservation_requires_approval: true)
    reservation = book
    input = attributes.merge(end_at: start_at + 16.hours)
    preview = ReservationService.preview(member: member, attributes: input, reservation: reservation)
    ReservationService.update!(reservation: reservation, attributes: input.merge(fee_confirmation: preview[:feeConfirmation]))
    expect(reservation.reload.status).to eq("pending")
    expect(reservation.invoice).to be_nil
    expect(described_class.total(reservation.fee_snapshot)).to eq(40)
    shop.update!(duration_fees: [])
    option.destroy
    ReservationService.approve!(reservation: reservation, actor: create(:member, :current))
    expect(reservation.fee_invoice.amount).to eq(40)
  end

  it "does not bill denied or cancelled requests awaiting approval" do
    shop.update!(reservation_requires_approval: true)
    denied = book
    actor = create(:member, :current)
    expect {
      ReservationService.deny!(reservation: denied, actor: actor)
    }.to have_enqueued_job(ReservationFeeNotificationJob).with(denied.id.to_s)
    cancelled = book
    ReservationService.cancel!(reservation: cancelled, actor: member)
    expect(Invoice.count).to eq(0)
    expect(denied.reload.invoice).to be_nil
    expect(cancelled.reload.invoice).to be_nil
  end

  it "releases unpaid reservations at start while preserving their invoice debt" do
    reservation = book
    expect {
      travel_to(start_at + 1.minute) { described_class.reconcile!(reservation) }
    }.to have_enqueued_job(ReservationFeeNotificationJob).with(reservation.id.to_s)
    expect(reservation.reload.status).to eq("cancelled")
    expect(reservation.fee_invoice.amount).to eq(30)
    expect(reservation.fee_invoice.settled).to eq(false)
  end
end
