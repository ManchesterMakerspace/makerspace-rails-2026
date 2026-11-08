require 'rails_helper'

RSpec.describe PayNowLimit do
  let(:subscription_id) { 'member_abc_123' }

  def refusal
    described_class.claim!(subscription_id)
    nil
  rescue PayNow::Refused => error
    error
  end

  it 'allows the first attempt and starts the cooldown' do
    expect(described_class.claim!(subscription_id)).to be(true)

    status = described_class.status(subscription_id)
    expect(status[:state]).to eq(:cooldown)
    expect(status[:retry_at]).to be_within(5.seconds).of(1.hour.from_now)
  end

  it 'refuses a second attempt during the cooldown with 429 and when to try again' do
    described_class.claim!(subscription_id)

    error = refusal

    expect(error).to be_a(PayNow::Refused)
    expect(error.status).to eq(429)
    expect(error.reason).to eq('cooldown')
    expect(error.message).to match(/wait an hour/i)
    expect(error.retry_at).to be_within(5.seconds).of(1.hour.from_now)
  end

  it 'allows three attempts a day, one after each cooldown, then refuses until tomorrow' do
    3.times do
      expect(described_class.claim!(subscription_id)).to be(true)
      clear_pay_now_cooldown
    end

    error = refusal

    expect(error.reason).to eq('daily_cap')
    expect(error.status).to eq(429)
    expect(error.message).to match(/today's limit of 3/i)
    expect(error.retry_at).to be_within(5.seconds).of(24.hours.from_now)
    expect(described_class.status(subscription_id)[:state]).to eq(:daily_cap)
  end

  it 'reports the daily cap, not the cooldown, when both apply' do
    3.times { described_class.claim!(subscription_id) rescue nil }
    REDIS.set("pay_now_day/#{subscription_id}", '3', ex: 3600)

    expect(refusal.reason).to eq('daily_cap')
  end

  it 'keeps the limits separate for each subscription' do
    described_class.claim!(subscription_id)

    expect(described_class.claim!('another_subscription')).to be(true)
  end

  it 'lets only one of two simultaneous attempts through' do
    results = Array.new(2) { Thread.new { refusal.nil? } }.map(&:value)

    expect(results.count(true)).to eq(1)
  end

  it 'gives an attempt back when it never reached Braintree' do
    described_class.claim!(subscription_id)

    described_class.release(subscription_id)

    expect(described_class.status(subscription_id)[:state]).to eq(:available)
    expect(REDIS.get("pay_now_day/#{subscription_id}").to_i).to eq(0)
  end

  it 'is available when nothing was attempted' do
    expect(described_class.status(subscription_id)).to eq(state: :available, retry_at: nil)
  end
end
