require 'swagger_helper'

describe 'Billing::Subscriptions API', type: :request do
  let(:sub_customer) { create(:member, customer_id: "foo") }
  let(:invoice) { create(:invoice, member: sub_customer) }
  let(:subscription) { build(:subscription, id: invoice.generate_subscription_id) }
  let(:customer) { create(:member, customer_id: "foobar") }
  let(:non_customer) { create(:member) }
  let(:gateway) { double }

  before do
    sub_customer.update(subscription_id: subscription.id)
    create(:permission, member: sub_customer, name: :billing, enabled: true )
    create(:permission, member: customer, name: :billing, enabled: true )
    create(:permission, member: non_customer, name: :billing, enabled: true )
    allow_any_instance_of(Service::BraintreeGateway).to receive(:connect_gateway).and_return(gateway)
  end

  path '/billing/subscriptions/{id}' do
    get 'Gets a subscription' do
      tags 'Subscriptions'
      operationId "getSubscription"
      consumes 'application/json'
      parameter name: :id, in: :path, type: :string

      response '200', 'subscription found' do
        before do
          sign_in sub_customer
          allow(BraintreeService::Subscription).to receive(:get_subscription).with(gateway, subscription.id).and_return(subscription)
        end

        schema '$ref' => '#/components/schemas/Subscription'

        let(:id) { subscription.id }

        run_test!
      end

      response '401', 'User not authenticated' do
        schema '$ref' => '#/components/schemas/error'
        let(:id) { subscription.id }
        run_test!
      end

      response '403', 'User not authorized' do
        before { sign_in non_customer }
        schema '$ref' => '#/components/schemas/error'
        let(:id) { subscription.id }
        run_test!
      end

      response '404', 'Subscription not for user' do
        before { sign_in customer }
        schema '$ref' => '#/components/schemas/error'
        let(:id) { subscription.id }
        run_test!
      end

      response '404', 'secondary household member cannot access household subscription' do
        let(:primary) { create(:member, customer_id: "primary_customer") }
        let(:secondary) { create(:member, customer_id: "secondary_customer") }
        let(:household_subscription_id) { "household_sub_123" }
        let(:id) { household_subscription_id }

        before do
          create(:permission, member: secondary, name: :billing, enabled: true)
          group = create(:group, member: primary, groupRep: primary.fullname, groupName: primary.id.to_s)
          group.update!(subscription_id: household_subscription_id)
          secondary.update!(groupName: group.groupName)
          sign_in secondary
        end

        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end

    put "Update a subscription" do
      tags 'Subscriptions'
      operationId "updateSubscription"
      consumes 'application/json'
      parameter name: :id, in: :path, type: :string
      parameter name: :updateSubscriptionDetails, in: :body, schema: {
        title: :updateSubscriptionDetails,
        type: :object,
        properties: {
          paymentMethodToken: { type: :string }
        },
        required: [:paymentMethodToken]
      }, required: true

      response '200', 'subscription updated' do
        before do
          sign_in sub_customer
          allow(BraintreeService::Subscription).to receive(:update).and_return(subscription)
        end

        schema '$ref' => '#/components/schemas/Subscription'

        let(:id) { subscription.id }
        let(:updateSubscriptionDetails) {{ payment_method_token: "54321" }}

        run_test!
      end

      response '401', 'User not authenticated' do
        schema '$ref' => '#/components/schemas/error'
        let(:id) { subscription.id }
        let(:updateSubscriptionDetails) {{ payment_method_token: "54321" }}
        run_test!
      end

      response '403', 'User not authorized' do
        before { sign_in non_customer }
        schema '$ref' => '#/components/schemas/error'
        let(:id) { subscription.id }
        let(:updateSubscriptionDetails) {{ payment_method_token: "54321" }}
        run_test!
      end

      response '404', 'Subscription not for user' do
        before { sign_in customer }
        schema '$ref' => '#/components/schemas/error'
        let(:id) { subscription.id }
        let(:updateSubscriptionDetails) {{ payment_method_token: "54321" }}
        run_test!
      end
    end

    delete 'Cancels a subscription' do
      let(:subscription) { build(:subscription, id: "foo") }
      before do
        allow(BraintreeService::Subscription).to receive(:cancel).with(gateway, subscription.id)
      end

      tags 'Subscriptions'
      operationId "cancelSubscription"
      parameter name: :id, in: :path, type: :string

      response '204', 'refund requested' do
        before { sign_in sub_customer }

        let(:id) { subscription.id }
        run_test!
      end

      response '401', 'User not authenticated' do
        schema '$ref' => '#/components/schemas/error'
        let(:id) { subscription.id }
        run_test!
      end

      response '403', 'User not authorized' do
        before { sign_in non_customer }
        schema '$ref' => '#/components/schemas/error'
        let(:id) { subscription.id }
        run_test!
      end

      response '404', 'Subscription not for user' do
        before { sign_in customer }
        schema '$ref' => '#/components/schemas/error'
        let(:id) { subscription.id }
        run_test!
      end

      response '404', 'secondary household member cannot cancel household subscription' do
        let(:primary) { create(:member, customer_id: "primary_customer") }
        let(:secondary) { create(:member, customer_id: "secondary_customer") }
        let(:household_subscription_id) { "household_sub_123" }
        let(:id) { household_subscription_id }

        before do
          create(:permission, member: secondary, name: :billing, enabled: true)
          group = create(:group, member: primary, groupRep: primary.fullname, groupName: primary.id.to_s)
          group.update!(subscription_id: household_subscription_id)
          secondary.update!(groupName: group.groupName)
          sign_in secondary
        end

        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end
  end
  path '/billing/subscriptions/{id}/pay_now' do
    post 'Pays the past-due balance of a subscription now' do
      tags 'Subscriptions'
      operationId "payNowSubscription"
      description "Charges the past-due balance of the member's own Braintree subscription right away, instead of waiting for " \
        "Braintree's retry. Only for a Past Due subscription. A hard decline blocks it until the payment method is changed; " \
        "attempts are limited to one an hour and three a day per subscription."
      consumes 'application/json'
      produces 'application/json'
      parameter name: :id, in: :path, type: :string

      let(:id) { subscription.id }
      let(:past_due) { build(:subscription, id: subscription.id, status: ::Braintree::Subscription::Status::PastDue) }
      # The member's one open invoice (a member can only have one), which the subscription id is generated from.
      let(:pay_now_invoice) do
        invoice.tap { |open| open.update!(subscription_id: subscription.id, plan_id: '33556', amount: 65.0, name: 'Monthly membership') }
      end

      def retry_result(success:, type: 'soft_declined', code: '2001')
        transaction = double(
          id: success ? 'tx_paid' : 'tx_declined', amount: BigDecimal('65.00'),
          status: success ? 'submitted_for_settlement' : 'processor_declined',
          processor_response_type: success ? 'approved' : type, processor_response_code: success ? '1000' : code,
          processor_response_text: success ? 'Approved' : 'Insufficient Funds', gateway_rejection_reason: nil,
          discounts: [], plan_id: '33556', subscription_id: subscription.id,
          customer_details: double(id: 'foo', first_name: 'Test', last_name: 'Member')
        )
        double(success?: success, transaction: transaction, message: nil)
      end

      before do
        pay_now_invoice
        create(:card, member: sub_customer)
        allow(BraintreeService::Notification).to receive(:enque_message)
        allow(::Service::SlackConnector).to receive(:enque_message)
        allow(BillingMailer).to receive_message_chain(:receipt, :deliver_later)
        allow(BraintreeService::Subscription).to receive(:get_subscription).with(gateway, subscription.id).and_return(past_due)
      end

      response '200', 'payment went through; the refreshed subscription' do
        before do
          sign_in sub_customer
          allow(BraintreeService::Subscription).to receive(:retry_charge).with(gateway, subscription.id).and_return(retry_result(success: true))
        end

        schema '$ref' => '#/components/schemas/Subscription'

        run_test!
      end

      response '422', 'payment was declined, or Pay now is not available (hard decline, not past due)' do
        before do
          sign_in sub_customer
          allow(BraintreeService::Subscription).to receive(:retry_charge).and_return(retry_result(success: false))
        end

        schema '$ref' => '#/components/schemas/PayNowRefusal'

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['error']).to eq('payment_declined')
          expect(body['failureMessage']).to eq('insufficient funds')
          expect(body['canPayNow']).to eq(false)
        end
      end

      response '422', 'hard decline blocks Pay now until the payment method is changed' do
        before do
          sign_in sub_customer
          pay_now_invoice.update!(last_failed_transaction_id: 'tx_old', last_failure_type: 'hard_declined', last_failure_message: 'the card has expired')
          expect(BraintreeService::Subscription).not_to receive(:retry_charge)
        end

        schema '$ref' => '#/components/schemas/PayNowRefusal'

        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to eq('hard_decline')
        end
      end

      response '429', 'cooldown between attempts, or the daily limit, reached' do
        before do
          sign_in sub_customer
          allow(BraintreeService::Subscription).to receive(:retry_charge).and_return(retry_result(success: false))
          PayNowLimit.claim!(subscription.id)
        end

        schema '$ref' => '#/components/schemas/PayNowRefusal'

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['error']).to eq('cooldown')
          expect(body['nextPayNowAt']).to be_present
        end
      end

      response '401', 'User not authenticated' do
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end

      response '403', 'User not authorized' do
        before { sign_in non_customer }
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end

      response '404', 'Subscription not for user' do
        before { sign_in customer }
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end

      response '404', 'secondary household member cannot pay the household subscription' do
        let(:primary) { create(:member, customer_id: "primary_customer") }
        let(:secondary) { create(:member, customer_id: "secondary_customer") }
        let(:id) { "household_sub_123" }

        before do
          create(:permission, member: secondary, name: :billing, enabled: true)
          group = create(:group, member: primary, groupRep: primary.fullname, groupName: primary.id.to_s)
          group.update!(subscription_id: id)
          secondary.update!(groupName: group.groupName)
          sign_in secondary
        end

        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end
  end
end
