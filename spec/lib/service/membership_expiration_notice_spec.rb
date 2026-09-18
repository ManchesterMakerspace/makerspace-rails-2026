require 'rails_helper'

RSpec.describe Service::MembershipExpirationNotice do
  let(:at) { Time.find_zone!('America/New_York').local(2026, 9, 20, 9, 0) }

  before do
    allow(MemberMailer).to receive(:membership_expiring_soon).and_return(double(deliver_later: true))
    allow(MemberMailer).to receive(:membership_expired).and_return(double(deliver_later: true))
    allow(Service::ErrorReporter).to receive(:notify)
  end

  def expiring_in(days)
    (at + days.days).to_i * 1000
  end

  def expired_days_ago(days)
    (at - days.days).to_i * 1000
  end

  it "emails a non-subscribed member expiring in exactly 3 days and records the sent expirationTime" do
    member = create(:member, subscription: false, subscription_id: nil, expirationTime: expiring_in(3))

    described_class.run!(at: at)

    expect(MemberMailer).to have_received(:membership_expiring_soon).with(member.id.as_json)
    expect(member.reload.membership_expiring_soon_notice_sent_for).to eq(member.expirationTime)
  end

  it "emails a non-subscribed member whose expiration passed exactly 1 day ago" do
    member = create(:member, subscription: false, subscription_id: nil, expirationTime: expired_days_ago(1))

    described_class.run!(at: at)

    expect(MemberMailer).to have_received(:membership_expired).with(member.id.as_json)
    expect(member.reload.membership_expired_notice_sent_for).to eq(member.expirationTime)
  end

  it "does not email a member with an active Braintree subscription" do
    create(:member, subscription: true, subscription_id: nil, expirationTime: expiring_in(3))
    create(:member, subscription: false, subscription_id: "sub-123", expirationTime: expiring_in(3))

    described_class.run!(at: at)

    expect(MemberMailer).not_to have_received(:membership_expiring_soon)
  end

  it "does not email a member with an active Earned Membership" do
    member = create(:member, subscription: false, subscription_id: nil, expirationTime: expiring_in(3))
    create(:earned_membership_no_requirements, member: member)

    described_class.run!(at: at)

    expect(MemberMailer).not_to have_received(:membership_expiring_soon)
  end

  it "does not email the Landlord/Fob placeholder" do
    create(:member, firstname: "Landlord", lastname: "Fob", subscription: false, subscription_id: nil, expirationTime: expiring_in(3))

    described_class.run!(at: at)

    expect(MemberMailer).not_to have_received(:membership_expiring_soon)
  end

  it "does not email a member whose status is no longer active" do
    create(:member, status: "revoked", subscription: false, subscription_id: nil, expirationTime: expiring_in(3))

    described_class.run!(at: at)

    expect(MemberMailer).not_to have_received(:membership_expiring_soon)
  end

  it "does not re-send the same notice twice for the same expiration" do
    member = create(:member, subscription: false, subscription_id: nil, expirationTime: expiring_in(3))

    described_class.run!(at: at)
    described_class.run!(at: at)

    expect(MemberMailer).to have_received(:membership_expiring_soon).once
  end

  it "sends again once the member renews to a new expiration" do
    member = create(:member, subscription: false, subscription_id: nil, expirationTime: expiring_in(3))
    described_class.run!(at: at)
    expect(MemberMailer).to have_received(:membership_expiring_soon).once

    member.update_attribute(:expirationTime, expiring_in(3) + 30.days.to_i * 1000)
    described_class.run!(at: at)

    expect(MemberMailer).to have_received(:membership_expiring_soon).twice
  end

  it "reports (but does not raise past) an error sending to one member, and still sends to others" do
    failing = create(:member, subscription: false, subscription_id: nil, expirationTime: expiring_in(3))
    succeeding = create(:member, subscription: false, subscription_id: nil, expirationTime: expiring_in(3))
    allow(MemberMailer).to receive(:membership_expiring_soon).with(failing.id.as_json).and_raise("boom")

    expect { described_class.run!(at: at) }.not_to raise_error

    expect(Service::ErrorReporter).to have_received(:notify)
    expect(MemberMailer).to have_received(:membership_expiring_soon).with(succeeding.id.as_json)
    expect(failing.reload.membership_expiring_soon_notice_sent_for).to be_nil
  end
end
