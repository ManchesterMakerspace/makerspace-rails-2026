# mock nonce from braintree  as appropriate
# "fake-valid-nonce"
# "fake-valid-no-billing-address-nonce"
# "fake-valid-visa-nonce"
# "fake-paypal-one-time-nonce"
# "fake-paypal-billing-agreement-nonce"
# "fake-processor-declined-visa-nonce"
# "fake-consumed-nonce"


#make transaction
# sale_result = gateway.transaction.sale(
#   amount: 100
#   payment_method_nonce: something
#   options: {
#     submit_for_settlement: true
#   }
# )

# Settle it
# result = gateway.testing.settle(sale_result.transaction.id)
# result.success?.should == true
# result.transaction.status.should == Braintree::Transactioon::Status::Settled


# # Decline it
# result = gateway.testing.settlement_delcine(sale_result.transaction.id)
# result.success?.should == true
# result.transaction.status.should == Braintree::Transactioon::Status::SettlmentDeclined



# instantly disputed transaction of any mount:
# test card number === 4023898493988028


require 'rails_helper'

RSpec.describe Billing::SubscriptionsController, type: :controller do
  let(:gateway) { double }
  let(:non_customer) { create(:member) }
  let(:member) { create(:member, customer_id: "bar") }
  let(:payment_method) { build(:payment_method, customer_id: "bar") }
  let(:invoice) { create(:invoice, member: member) }
  let(:subscription) { build(:subscription, id: "foobar") }

  let(:failed_result) { double(success?: false) }
  let(:success_result) { double(success?: true) }

  let(:valid_params) {
    {
      payment_method_token: "some_token",
    }
  }

  before(:each) do
    create(:billing_permission, member: member)
    create(:billing_permission, member: non_customer)
    allow_any_instance_of(Service::BraintreeGateway).to receive(:connect_gateway).and_return(gateway)
    @request.env["devise.mapping"] = Devise.mappings[:member]
    sign_in member
  end

  describe "GET #show" do
    it "fetches a subscription for customer" do
      # Mock current_member call to use double
      allow_any_instance_of(Billing::SubscriptionsController).to receive(:current_member).and_return(member)
      allow(member).to receive(:find_subscribed_resource).with("foobar").and_return(member)
      expect(member).to receive(:find_subscribed_resource).with("foobar").and_return(member)

      allow(::BraintreeService::Subscription).to receive(:get_subscription).with(gateway, "foobar").and_return(subscription)
      get :show, params: { id: "foobar" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response['id']).to eq("foobar")
    end

    it "Raises error if subscription is not for customer" do
      # Mock current_member call to use double
      allow_any_instance_of(Billing::SubscriptionsController).to receive(:current_member).and_return(member)
      allow(member).to receive(:find_subscribed_resource).with("foobar").and_return(nil)
      expect(member).to receive(:find_subscribed_resource).with("foobar").and_return(nil)

      get :show, params: { id: "foobar" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(404)
      expect(parsed_response['message']).to match(/resource not found/i)
    end

    it "raises error if no customer" do
      sign_in non_customer
      get :show, params: { id: "foobar" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(403)
      expect(parsed_response['message']).to match(/customer/i)
    end
  end

  describe "PUT #update" do
    it "updates a subscription for customer" do
      update_hash = {
        id: "foobar",
        payment_method_token: valid_params[:payment_method_token]
      }
      allow_any_instance_of(Billing::SubscriptionsController).to receive(:current_member).and_return(member)
      allow_any_instance_of(Billing::SubscriptionsController).to receive(:subscription_params).and_return(valid_params)
      allow(member).to receive(:find_subscribed_resource).with("foobar").and_return(member)
      expect(member).to receive(:find_subscribed_resource).with("foobar").and_return(member)
      allow(::BraintreeService::Subscription).to receive(:update).with(gateway, update_hash).and_return(subscription)
      expect(::BraintreeService::Subscription).to receive(:update).with(gateway, update_hash).and_return(subscription)

      put :update, params: { id: "foobar", subscription: valid_params }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response['id']).to eq(subscription.id)
    end

    it "Raises error if subscription is not for customer" do
      # Mock current_member call to use double
      allow_any_instance_of(Billing::SubscriptionsController).to receive(:current_member).and_return(member)
      allow(member).to receive(:find_subscribed_resource).with("foobar").and_return(nil)
      expect(member).to receive(:find_subscribed_resource).with("foobar").and_return(nil)

      put :update, params: { id: "foobar", subscription: valid_params }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(404)
      expect(parsed_response['message']).to match(/resource not found/i)
    end

    it "raises error if no customer" do
      sign_in non_customer
      put :update, params: { id: "foobar", subscription: valid_params }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(403)
      expect(parsed_response['message']).to match(/customer/i)
    end
  end

  describe "GET #cancellation_impact" do
    it "returns reservations that will be cancelled with the membership subscription" do
      impacted = instance_double(
        Reservation,
        id: BSON::ObjectId.new,
        title: "Woodshop project",
        calendar_html_link: "https://calendar.google.com/calendar/event?eid=example",
        start_at: 1.day.from_now,
        end_at: 2.days.from_now
      )
      allow_any_instance_of(Billing::SubscriptionsController).to receive(:current_member).and_return(member)
      allow(member).to receive(:find_subscribed_resource).with("foobar").and_return(member)
      allow(ReservationLifecycleService).to receive(:cancellation_impact).with(member).and_return([impacted])

      get :cancellation_impact, params: { id: "foobar" }, format: :json

      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(parsed_response["reservationCount"]).to eq(1)
      expect(parsed_response["reservations"].first["title"]).to eq("Woodshop project")
      expect(parsed_response["reservations"].first["calendarHtmlLink"]).to eq(
        impacted.calendar_html_link
      )
    end
  end

  describe "DELETE #destroy" do
    it "Cancels subscription for member" do
      allow_any_instance_of(Billing::SubscriptionsController).to receive(:current_member).and_return(member)
      allow(member).to receive(:find_subscribed_resource).with("foobar").and_return(member)
      expect(member).to receive(:find_subscribed_resource).with("foobar").and_return(member)
      allow(::BraintreeService::Subscription).to receive(:cancel).with(gateway, "foobar").and_return(success_result)
      expect(::BraintreeService::Subscription).to receive(:cancel).with(gateway, "foobar").and_return(success_result)
      allow(success_result).to receive(:subscription).and_return(subscription)

      delete :destroy, params: { id: "foobar" }, format: :json
      expect(response).to have_http_status(204)
    end

    it "Raises error if subscription is not for customer" do
      # Mock current_member call to use double
      allow_any_instance_of(Billing::SubscriptionsController).to receive(:current_member).and_return(member)
      allow(member).to receive(:find_subscribed_resource).with("foobar").and_return(nil)
      expect(member).to receive(:find_subscribed_resource).with("foobar").and_return(nil)

      delete :destroy, params: { id: "foobar" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(404)
      expect(parsed_response['message']).to match(/resource not found/i)
    end

    it "raises error if no customer" do
      sign_in non_customer
      delete :destroy, params: { id: "foobar" }, format: :json
      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(403)
      expect(parsed_response['message']).to match(/customer/i)
    end
  end
  describe "POST #pay_now" do
    let(:past_due_subscription) { build(:subscription, id: "foobar", status: ::Braintree::Subscription::Status::PastDue) }
    let(:failure) { { type: "soft_declined", message: "insufficient funds", code: "2001", text: "Insufficient Funds" } }

    before do
      allow_any_instance_of(Billing::SubscriptionsController).to receive(:current_member).and_return(member)
      allow(member).to receive(:find_subscribed_resource).with("foobar").and_return(member)
      allow(::BraintreeService::Subscription).to receive(:get_subscription).with(gateway, "foobar").and_return(past_due_subscription)
    end

    it "returns the refreshed subscription when the payment goes through" do
      active = build(:subscription, id: "foobar", status: ::Braintree::Subscription::Status::Active)
      allow(::BraintreeService::Subscription).to receive(:get_subscription).with(gateway, "foobar").and_return(active)
      expect(::PayNow).to receive(:attempt!).with(gateway, member, "foobar").and_return(::PayNow::Outcome.new(paid: true))

      post :pay_now, params: { id: "foobar" }, format: :json

      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(200)
      expect(parsed_response["status"]).to eq("Active")
      expect(parsed_response["canPayNow"]).to eq(false)
    end

    it "answers a decline with 422, the reason, and whether and when to try again" do
      invoice = create(:invoice, member: member, subscription_id: "foobar", last_failure_message: "insufficient funds")
      allow(::PayNow).to receive(:attempt!).and_return(::PayNow::Outcome.new(paid: false, invoice: invoice, failure: failure))

      post :pay_now, params: { id: "foobar" }, format: :json

      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(422)
      expect(parsed_response["error"]).to eq("payment_declined")
      expect(parsed_response["message"]).to eq("Your payment did not go through: insufficient funds.")
      expect(parsed_response["failureType"]).to eq("soft_declined")
      expect(parsed_response["failureMessage"]).to eq("insufficient funds")
      expect(parsed_response).to have_key("canPayNow")
      expect(parsed_response).to have_key("nextPayNowAt")
    end

    it "tells the member to update the payment method after a hard decline" do
      invoice = create(:invoice, member: member, subscription_id: "foobar", last_failure_type: "hard_declined", last_failure_message: "the card has expired")
      hard = failure.merge(type: "hard_declined", message: "the card has expired")
      allow(::PayNow).to receive(:attempt!).and_return(::PayNow::Outcome.new(paid: false, invoice: invoice, failure: hard))

      post :pay_now, params: { id: "foobar" }, format: :json

      parsed_response = JSON.parse(response.body)
      expect(parsed_response["message"]).to match(/the card has expired.*update your payment method/i)
      expect(parsed_response["payNowBlockedReason"]).to eq("hard_decline")
      expect(parsed_response["canPayNow"]).to eq(false)
    end

    it "answers 429 with when to try again when the cooldown or daily cap applies" do
      retry_at = 1.hour.from_now
      allow(::PayNow).to receive(:attempt!).and_raise(::PayNow::Refused.new(429, "cooldown", "Wait an hour.", retry_at))

      post :pay_now, params: { id: "foobar" }, format: :json

      parsed_response = JSON.parse(response.body)
      expect(response).to have_http_status(429)
      expect(parsed_response["error"]).to eq("cooldown")
      expect(Time.iso8601(parsed_response["nextPayNowAt"])).to be_within(1.second).of(retry_at)
    end

    it "answers 422 for a hard decline refused before reaching Braintree" do
      allow(::PayNow).to receive(:attempt!).and_raise(::PayNow::Refused.new(422, "hard_decline", "Update your payment method first."))

      post :pay_now, params: { id: "foobar" }, format: :json

      expect(response).to have_http_status(422)
      expect(JSON.parse(response.body)["error"]).to eq("hard_decline")
    end

    it "does not run for a subscription that is not the member's own" do
      allow(member).to receive(:find_subscribed_resource).with("foobar").and_return(nil)
      expect(::PayNow).not_to receive(:attempt!)

      post :pay_now, params: { id: "foobar" }, format: :json

      expect(response).to have_http_status(404)
    end

    it "does not run for a member without a Braintree customer" do
      allow_any_instance_of(Billing::SubscriptionsController).to receive(:current_member).and_return(non_customer)
      expect(::PayNow).not_to receive(:attempt!)

      post :pay_now, params: { id: "foobar" }, format: :json

      expect(response).to have_http_status(403)
    end
  end

  describe "PUT #update after a hard decline" do
    it "lifts the hard decline so Pay now is available again" do
      invoice = create(:invoice, member: member, subscription_id: "foobar", last_failed_transaction_id: "tx_1", last_failure_type: "hard_declined", last_failure_message: "the card has expired")
      allow_any_instance_of(Billing::SubscriptionsController).to receive(:current_member).and_return(member)
      allow(member).to receive(:find_subscribed_resource).with("foobar").and_return(member)
      allow(::BraintreeService::Subscription).to receive(:update).and_return(subscription)

      put :update, params: { id: "foobar", payment_method_token: "new_token" }, format: :json

      expect(response).to have_http_status(200)
      expect(PaymentFailure.hard_decline?(invoice.reload)).to be(false)
    end
  end

  describe "GET #show" do
    it "reads the reason for a failure from before reasons were stored" do
      past_due = build(:subscription, id: "foobar", status: ::Braintree::Subscription::Status::PastDue)
      allow_any_instance_of(Billing::SubscriptionsController).to receive(:current_member).and_return(member)
      allow(member).to receive(:find_subscribed_resource).with("foobar").and_return(member)
      allow(::BraintreeService::Subscription).to receive(:get_subscription).with(gateway, "foobar").and_return(past_due)
      expect(::PayNow).to receive(:ensure_failure_reason).with(gateway, past_due).and_call_original

      get :show, params: { id: "foobar" }, format: :json

      expect(response).to have_http_status(200)
    end
  end
end
