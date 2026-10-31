require 'rails_helper'

RSpec.describe Service::MemberReminders do
  let(:at) { Time.find_zone!('America/New_York').local(2026, 9, 20, 9, 30) }

  before do
    allow(MemberMailer).to receive(:fob_reminder).and_return(double(deliver_later: true))
    allow(MemberMailer).to receive(:signup_reminder).and_return(double(deliver_later: true))
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::ErrorReporter).to receive(:notify)
    SystemConfig.set(SystemConfig::FOB_REMINDER_ENABLED, 'true')
    SystemConfig.set(SystemConfig::SIGNUP_REMINDER_ENABLED, 'true')
  end

  def days_ago(days)
    at - days.days
  end

  def paid_member(paid_days_ago:, **attrs)
    member = create(:member, { status: 'activeMember', expirationTime: nil }.merge(attrs))
    create(:invoice, member: member, transaction_id: "txn_#{SecureRandom.hex(4)}", created_at: days_ago(paid_days_ago))
    member
  end

  def pending_member(signed_up_days_ago:, **attrs)
    create(:member, { status: 'pending', expirationTime: nil, startDate: days_ago(signed_up_days_ago) }.merge(attrs))
  end

  describe ".due?" do
    def due(count:, elapsed:, last_sent_days_ago: nil, first_wait: 8)
      today = at.to_date
      described_class.due?(count: count, last_sent_at: last_sent_days_ago && days_ago(last_sent_days_ago),
                           elapsed_days: elapsed, first_wait: first_wait, today: today)
    end

    it "sends the first reminder from day 8 and not before" do
      expect(due(count: 0, elapsed: 7)).to be(false)
      expect(due(count: 0, elapsed: 8)).to be(true)
    end

    it "catches up a first reminder that is overdue but inside the 30 day cutoff" do
      expect(due(count: 0, elapsed: 25)).to be(true)
      expect(due(count: 0, elapsed: 30)).to be(true)
      expect(due(count: 0, elapsed: 31)).to be(false)
    end

    it "sends the second reminder from day 22, at least 14 days after the first" do
      expect(due(count: 1, elapsed: 21, last_sent_days_ago: 14)).to be(false)
      expect(due(count: 1, elapsed: 22, last_sent_days_ago: 14)).to be(true)
      expect(due(count: 1, elapsed: 25, last_sent_days_ago: 5)).to be(false)
    end

    it "never sends a third" do
      expect(due(count: 2, elapsed: 25, last_sent_days_ago: 20)).to be(false)
    end

    it "moves both reminders with the days setting" do
      expect(due(count: 0, elapsed: 4, first_wait: 4)).to be(true)
      expect(due(count: 1, elapsed: 18, first_wait: 4, last_sent_days_ago: 14)).to be(true)
    end
  end

  describe "fob reminder" do
    it "emails and Slack-DMs a member who paid 8 days ago and has no fob, and records it" do
      member = paid_member(paid_days_ago: 8)
      allow_any_instance_of(Member).to receive(:slack_user).and_return(double(slack_id: 'U123'))

      expect(described_class.run!(at: at)).to eq(fob: 1, signup: 0)

      expect(MemberMailer).to have_received(:fob_reminder).with(member.id.as_json, days_ago(8).to_date.iso8601)
      expect(Service::SlackConnector).to have_received(:send_slack_message).with(a_string_matching(/key fob/), 'U123')
      member.reload
      expect(member.fob_reminder_count).to eq(1)
      expect(member.fob_reminder_last_sent_at).to be_present
    end

    it "does not email before day 8" do
      paid_member(paid_days_ago: 7)

      described_class.run!(at: at)

      expect(MemberMailer).not_to have_received(:fob_reminder)
    end

    it "does not send the same reminder twice in one day" do
      paid_member(paid_days_ago: 8)

      described_class.run!(at: at)
      described_class.run!(at: at)

      expect(MemberMailer).to have_received(:fob_reminder).once
    end

    it "sends the second reminder 14 days after the first" do
      member = paid_member(paid_days_ago: 22, fob_reminder_count: 1, fob_reminder_last_sent_at: days_ago(14))

      described_class.run!(at: at)

      expect(MemberMailer).to have_received(:fob_reminder).with(member.id.as_json, days_ago(22).to_date.iso8601)
      expect(member.reload.fob_reminder_count).to eq(2)
    end

    it "stops after two reminders" do
      paid_member(paid_days_ago: 28, fob_reminder_count: 2, fob_reminder_last_sent_at: days_ago(6))

      described_class.run!(at: at)

      expect(MemberMailer).not_to have_received(:fob_reminder)
    end

    it "sends nothing once 30 days have passed since the first payment" do
      paid_member(paid_days_ago: 31)

      described_class.run!(at: at)

      expect(MemberMailer).not_to have_received(:fob_reminder)
    end

    it "ignores a member whose first payment was long ago even if they paid again recently" do
      member = paid_member(paid_days_ago: 60)
      create(:invoice, member: member, transaction_id: "txn_recent", created_at: days_ago(8))

      described_class.run!(at: at)

      expect(MemberMailer).not_to have_received(:fob_reminder)
    end

    it "skips a member who has a fob" do
      member = paid_member(paid_days_ago: 8)
      create(:card, member: member, uid: SecureRandom.hex(6))

      described_class.run!(at: at)

      expect(MemberMailer).not_to have_received(:fob_reminder)
    end

    %w[inactive nonMember revoked suspended].each do |status|
      it "skips a #{status} member" do
        paid_member(paid_days_ago: 8, status: status)

        described_class.run!(at: at)

        expect(MemberMailer).not_to have_received(:fob_reminder)
      end
    end

    it "skips a member whose only payment was refunded" do
      member = create(:member, status: 'activeMember', expirationTime: nil)
      create(:invoice, member: member, transaction_id: "txn_refunded", refunded: true, created_at: days_ago(8))

      described_class.run!(at: at)

      expect(MemberMailer).not_to have_received(:fob_reminder)
    end

    it "skips a member whose only payment has a refund requested" do
      member = create(:member, status: 'activeMember', expirationTime: nil)
      create(:invoice, member: member, transaction_id: "txn_asked", refund_requested: days_ago(7), created_at: days_ago(8))

      described_class.run!(at: at)

      expect(MemberMailer).not_to have_received(:fob_reminder)
    end

    it "skips the landlord account and a member with an active Earned Membership" do
      paid_member(paid_days_ago: 8, firstname: 'Landlord', lastname: 'Fob')
      earned = paid_member(paid_days_ago: 8)
      create(:earned_membership, member: earned, status: 'active')

      described_class.run!(at: at)

      expect(MemberMailer).not_to have_received(:fob_reminder)
    end

    it "uses the days-after-payment setting" do
      SystemConfig.set(SystemConfig::FOB_REMINDER_DAYS, '3')
      paid_member(paid_days_ago: 4)

      described_class.run!(at: at)

      expect(MemberMailer).to have_received(:fob_reminder).once
    end

    it "sends nothing while the fob reminder is switched off" do
      SystemConfig.set(SystemConfig::FOB_REMINDER_ENABLED, 'false')
      paid_member(paid_days_ago: 8)

      expect(described_class.run!(at: at)).to eq(fob: 0, signup: 0)

      expect(MemberMailer).not_to have_received(:fob_reminder)
    end

    it "reports a failure and keeps going with the next member" do
      first = paid_member(paid_days_ago: 8)
      second = paid_member(paid_days_ago: 9)
      allow(MemberMailer).to receive(:fob_reminder).with(first.id.as_json, anything).and_raise('mail is down')

      expect(described_class.run!(at: at)).to eq(fob: 1, signup: 0)

      expect(Service::ErrorReporter).to have_received(:notify).once
      expect(first.reload.fob_reminder_count).to eq(0)
      expect(second.reload.fob_reminder_count).to eq(1)
    end

    it "still counts the email as sent when only the Slack DM fails" do
      member = paid_member(paid_days_ago: 8)
      allow_any_instance_of(Member).to receive(:slack_user).and_return(double(slack_id: 'U123'))
      allow(Service::SlackConnector).to receive(:send_slack_message).and_raise('slack is down')

      expect(described_class.run!(at: at)).to eq(fob: 1, signup: 0)

      expect(member.reload.fob_reminder_count).to eq(1)
    end
  end

  describe "signup reminder" do
    it "emails a pending member who signed up 8 days ago and has not paid" do
      member = pending_member(signed_up_days_ago: 8)

      expect(described_class.run!(at: at)).to eq(fob: 0, signup: 1)

      expect(MemberMailer).to have_received(:signup_reminder).with(member.id.as_json)
      expect(member.reload.signup_reminder_count).to eq(1)
    end

    it "does not email before day 8" do
      pending_member(signed_up_days_ago: 7)

      described_class.run!(at: at)

      expect(MemberMailer).not_to have_received(:signup_reminder)
    end

    it "sends the second reminder on day 22" do
      member = pending_member(signed_up_days_ago: 22, signup_reminder_count: 1, signup_reminder_last_sent_at: days_ago(14))

      described_class.run!(at: at)

      expect(member.reload.signup_reminder_count).to eq(2)
    end

    it "skips signups older than 30 days" do
      pending_member(signed_up_days_ago: 31)

      described_class.run!(at: at)

      expect(MemberMailer).not_to have_received(:signup_reminder)
    end

    it "never reaches the older accounts that are activeMember with no payment" do
      create(:member, status: 'activeMember', expirationTime: nil, startDate: days_ago(8))

      described_class.run!(at: at)

      expect(MemberMailer).not_to have_received(:signup_reminder)
    end

    it "skips a pending member who has started to pay" do
      member = pending_member(signed_up_days_ago: 8)
      create(:invoice, member: member, created_at: days_ago(7))

      described_class.run!(at: at)

      expect(MemberMailer).not_to have_received(:signup_reminder)
    end

    it "skips a pending member who has a fob" do
      member = pending_member(signed_up_days_ago: 8)
      create(:card, member: member, uid: SecureRandom.hex(6))

      described_class.run!(at: at)

      expect(MemberMailer).not_to have_received(:signup_reminder)
    end

    it "uses the days-after-signup setting and can be switched off" do
      SystemConfig.set(SystemConfig::SIGNUP_REMINDER_DAYS, '2')
      pending_member(signed_up_days_ago: 3)

      described_class.run!(at: at)
      expect(MemberMailer).to have_received(:signup_reminder).once

      SystemConfig.set(SystemConfig::SIGNUP_REMINDER_ENABLED, 'false')
      other = pending_member(signed_up_days_ago: 3)
      described_class.run!(at: at)
      expect(other.reload.signup_reminder_count).to eq(0)
    end
  end
end
