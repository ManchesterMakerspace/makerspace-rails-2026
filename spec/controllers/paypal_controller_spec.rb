require 'rails_helper'
require 'securerandom'

RSpec.describe PaypalController, type: :controller do

  let(:member) { create(:member) }
  let(:valid_attributes) {
    {
      item_name: '1-month Subscription',
      item_number: 'Sub-Stnd-Membership',
      first_name: 'firstname',
      last_name: 'lastname',
      mc_gross: "65.0",
      mc_currency: "USD",
      payment_status: 'Completed',
      payer_email: member.email,
      txn_type: 'cart',
      txn_id: SecureRandom.uuid
    }
  }

  describe "POST #notify" do
    context "with valid params" do
      before(:each) do
        member
        REDIS.flushall
        sleep(5.seconds)
        allow(::PayPal::SDK::Core::API::IPN).to receive(:valid?).and_return(true)
      end 
      it "creates a new Paypal" do
        expect {
          post :notify, params: valid_attributes, format: :json
        }.to change(Payment, :count).by(1)
      end

      it "assigns a newly created paypal as @paypal" do
        post :notify, params: valid_attributes, format: :json
        expect(Payment.last).to be_a(Payment)
        expect(Payment.last).to be_persisted
      end

      it "Sends a notification to Slack" do
        expect(SlackMessagesJob).to receive(:perform_later)
        post :notify, params: valid_attributes, format: :json
      end

      it "includes a short registration email hash in links for unmatched payers" do
        original_token = ENV["REGISTRATION_EMAIL_TOKEN"]
        ENV["REGISTRATION_EMAIL_TOKEN"] = "slack registration/secret"
        valid_attributes[:payer_email] = "new+payer@example.com"

        post :notify, params: valid_attributes, format: :json

        messages = REDIS.mget(*REDIS.keys).map { |payload| JSON.load(payload)["message"] }
        expected_hash = OpenSSL::HMAC.hexdigest(
          "SHA256", "slack registration/secret", "new+payer@example.com"
        ).first(16)
        expect(messages.join("\n")).to include(
          "/send-registration/new%2Bpayer%40example.com?token=#{expected_hash}"
        )
        expect(messages.join("\n")).not_to include("slack%20registration%2Fsecret")
      ensure
        ENV["REGISTRATION_EMAIL_TOKEN"] = original_token
      end

      it "Attributes the correct member to the payment" do
        post :notify, params: valid_attributes, format: :json
        expect(Payment.last.member).to eq(member)
      end

      it "Updates member to subscription for correct txn_type" do
        expect(member.subscription).to be_falsey
        valid_attributes[:txn_type] = "subscr_payment"
        post :notify, params: valid_attributes, format: :json
        member.reload
        expect(member.subscription).to be_truthy
      end

      it "Updates member off subscription for correct txn_type" do
        expect(member.subscription).to be_falsey
        valid_attributes[:txn_type] = "subscr_payment"
        post :notify, params: valid_attributes, format: :json
        member.reload
        expect(member.subscription).to be_truthy
        valid_attributes[:txn_type] = "subscr_cancel"
        valid_attributes[:txn_id] = SecureRandom.uuid
        post :notify, params: valid_attributes, format: :json
        member.reload
        expect(member.subscription).to be_falsey
      end

      it "Notifies of duplicate txn_ids" do
        ActiveJob::Base.queue_adapter = :test
        post :notify, params: valid_attributes, format: :json
        expect {
          post :notify, params: valid_attributes, format: :json
        }.to have_enqueued_job
        messages = REDIS.mget(*REDIS.keys)
        sorted_messages = messages.sort_by { |payload| Time.parse(JSON.load(payload)["timestamp"]) }
        expect(JSON.load(sorted_messages.last)["message"]).to include("already been taken")
      end
    end
  end
end
