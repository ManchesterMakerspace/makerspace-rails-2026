require 'rails_helper'

# Braintree is never called: the gateway is a double, and the subscription and the retry result are built by hand.
RSpec.describe PayNow do
  let(:member) { create(:member, customer_id: 'cust_1') }
  let(:subscription_id) { 'member_sub_1' }
  let(:invoice) do
    create(:invoice, member: member, subscription_id: subscription_id, plan_id: '33556', amount: 65.0, name: 'Monthly membership')
  end
  let(:gateway) { double('gateway', subscription: double('subscription_gateway'), transaction: double('transaction_gateway')) }
  let(:status) { ::Braintree::Subscription::Status::PastDue }
  let(:braintree_subscription) { build(:subscription, id: subscription_id, status: status) }

  def charge(id:, success:, type: 'soft_declined', code: '2001', text: 'Insufficient Funds')
    double(
      id: id,
      amount: BigDecimal('65.00'),
      status: success ? 'submitted_for_settlement' : 'processor_declined',
      processor_response_type: success ? 'approved' : type,
      processor_response_code: success ? '1000' : code,
      processor_response_text: success ? 'Approved' : text,
      gateway_rejection_reason: nil,
      discounts: [],
      customer_details: double(id: 'cust_1', first_name: 'Test', last_name: 'Member'),
      plan_id: '33556',
      subscription_id: subscription_id
    )
  end

  def result(transaction, success:, message: nil)
    double('result', success?: success, transaction: transaction, message: message)
  end

  before do
    create(:card, member: member) # a membership payment is held until the member has a fob
    invoice
    allow(BraintreeService::Subscription).to receive(:get_subscription).with(gateway, subscription_id).and_return(braintree_subscription)
    allow(BraintreeService::Notification).to receive(:enque_message)
    allow(::Service::SlackConnector).to receive(:enque_message)
    allow(BillingMailer).to receive_message_chain(:receipt, :deliver_later)
  end

  describe '.attempt!' do
    context 'when the charge goes through' do
      let(:paid) { charge(id: 'tx_paid', success: true) }

      before do
        allow(BraintreeService::Subscription).to receive(:retry_charge).with(gateway, subscription_id).and_return(result(paid, success: true))
      end

      it 'settles the invoice through the existing success handling and extends the membership at once' do
        before_expiry = member.reload.expirationTime.to_i

        outcome = described_class.attempt!(gateway, member, subscription_id)

        expect(outcome).to be_paid
        invoice.reload
        expect(invoice.transaction_id).to eq('tx_paid')
        expect(invoice.settled).to be(true)
        expect(member.reload.expirationTime.to_i).to be > before_expiry
      end

      it 'marks the charge as handled so Braintree\'s own notification for it is not processed again' do
        described_class.attempt!(gateway, member, subscription_id)

        expect(described_class.handled?('tx_paid')).to be(true)
        expect(BraintreeService::Notification).not_to receive(:process_success)

        BraintreeService::Notification.send(:process_subscription_charge_success, invoice.reload, paid)
      end

      it 'writes an audit entry and tells board members' do
        described_class.attempt!(gateway, member, subscription_id)

        log = AuditLog.where(event_type: 'subscription_pay_now').first
        expect(log).to be_present
        expect(log.after_snapshot['outcome']).to eq('paid')
        expect(::Service::SlackConnector).to have_received(:enque_message).with(
          /paid their past-due Monthly membership payment of \$65\.00 with Pay now/,
          anything,
          anything
        )
      end

      it 'calls Braintree with no amount override' do
        expect(BraintreeService::Subscription).to receive(:retry_charge).with(gateway, subscription_id).and_return(result(paid, success: true))

        described_class.attempt!(gateway, member, subscription_id)
      end
    end

    context 'when the charge is declined' do
      let(:declined) { charge(id: 'tx_declined', success: false) }

      before do
        allow(BraintreeService::Subscription).to receive(:retry_charge).and_return(result(declined, success: false))
      end

      it 'stores why and leaves the invoice unpaid' do
        outcome = described_class.attempt!(gateway, member, subscription_id)

        expect(outcome).not_to be_paid
        expect(outcome.failure).to include(type: 'soft_declined', message: 'insufficient funds')
        invoice.reload
        expect(invoice.settled).to be(false)
        expect(invoice.transaction_id).to be_nil
        expect(invoice.last_failed_transaction_id).to eq('tx_declined')
        expect(invoice.last_failure_message).to eq('insufficient funds')
      end

      it 'tells board members the reason, the decline type and the bank response, and writes an audit entry' do
        described_class.attempt!(gateway, member, subscription_id)

        expect(::Service::SlackConnector).to have_received(:enque_message).with(
          /declined \(insufficient funds\) \[soft declined, response 2001 \(Insufficient Funds\)\]/,
          anything,
          anything
        )
        expect(AuditLog.where(event_type: 'subscription_pay_now').first.after_snapshot['outcome']).to eq('declined')
      end

      it 'does not email or message the member' do
        expect(BillingMailer).not_to receive(:failed_payment)

        described_class.attempt!(gateway, member, subscription_id)

        expect(BraintreeService::Notification).not_to have_received(:enque_message)
      end

      it 'keeps the button for a soft decline' do
        described_class.attempt!(gateway, member, subscription_id)

        expect(PaymentFailure.hard_decline?(invoice.reload)).to be(false)
      end

      context 'with a hard decline' do
        let(:declined) { charge(id: 'tx_hard', success: false, type: 'hard_declined', code: '2004', text: 'Expired Card') }

        it 'disables further attempts until the payment method changes' do
          described_class.attempt!(gateway, member, subscription_id)
          clear_pay_now_cooldown

          expect(PaymentFailure.hard_decline?(invoice.reload)).to be(true)
          expect(BraintreeService::Subscription).not_to receive(:retry_charge)
          expect { described_class.attempt!(gateway, member, subscription_id) }.to raise_error(PayNow::Refused) { |error|
            expect(error.reason).to eq('hard_decline')
            expect(error.status).to eq(422)
            expect(error.message).to match(/update your payment method/i)
          }
        end
      end
    end

    context 'when it must not charge' do
      it 'refuses a subscription that is not past due without calling Braintree' do
        braintree_subscription.instance_variable_set(:@status, ::Braintree::Subscription::Status::Active)
        expect(BraintreeService::Subscription).not_to receive(:retry_charge)

        expect { described_class.attempt!(gateway, member, subscription_id) }
          .to raise_error(::Error::UnprocessableEntity, /not past due/i)
      end

      it 'refuses when there is no unpaid invoice for the subscription' do
        invoice.update!(settled_at: Time.now)
        expect(BraintreeService::Subscription).not_to receive(:retry_charge)

        expect { described_class.attempt!(gateway, member, subscription_id) }
          .to raise_error(::Error::UnprocessableEntity, /unpaid invoice/i)
      end

      it 'sends a second press during the cooldown nowhere near Braintree' do
        allow(BraintreeService::Subscription).to receive(:retry_charge).and_return(result(charge(id: 'tx_1', success: false), success: false))
        described_class.attempt!(gateway, member, subscription_id)

        expect(BraintreeService::Subscription).not_to receive(:retry_charge)
        expect { described_class.attempt!(gateway, member, subscription_id) }.to raise_error(PayNow::Refused) { |error|
          expect(error.status).to eq(429)
          expect(error.reason).to eq('cooldown')
          expect(error.retry_at).to be_present
        }
      end

      it 'refuses a fourth attempt in a day' do
        allow(BraintreeService::Subscription).to receive(:retry_charge).and_return(result(charge(id: 'tx_1', success: false), success: false))
        3.times do
          described_class.attempt!(gateway, member, subscription_id)
          clear_pay_now_cooldown
        end

        expect { described_class.attempt!(gateway, member, subscription_id) }
          .to raise_error(PayNow::Refused) { |error| expect(error.reason).to eq('daily_cap') }
      end

      it 'reads a failure from before reasons were stored and refuses a hard decline found there' do
        invoice.update!(last_failed_transaction_id: 'tx_old')
        old = charge(id: 'tx_old', success: false, type: 'hard_declined', code: '2007', text: 'No Account')
        allow(gateway.transaction).to receive(:find).with('tx_old').and_return(old)
        expect(BraintreeService::Subscription).not_to receive(:retry_charge)

        expect { described_class.attempt!(gateway, member, subscription_id) }
          .to raise_error(PayNow::Refused) { |error| expect(error.reason).to eq('hard_decline') }
      end
    end

    context 'when Braintree does not attempt a charge' do
      it 'raises and gives the attempt back, so the member is not locked out for nothing' do
        allow(BraintreeService::Subscription).to receive(:retry_charge).and_raise(::Error::UnprocessableEntity.new('Subscription status must be Past Due in order to retry.'))

        expect { described_class.attempt!(gateway, member, subscription_id) }.to raise_error(::Error::UnprocessableEntity)

        expect(PayNowLimit.status(subscription_id)[:state]).to eq(:available)
      end
    end
  end

  describe '.info_for' do
    it 'allows an eligible past-due subscription, with the reason of the last failure' do
      invoice.update!(last_failed_transaction_id: 'tx_1', last_failure_type: 'soft_declined', last_failure_message: 'insufficient funds')

      expect(described_class.info_for(braintree_subscription)).to eq(
        can_pay_now: true, blocked_reason: nil, next_at: nil, failure_message: 'insufficient funds'
      )
    end

    it 'blocks a hard decline until the payment method changes' do
      invoice.update!(last_failed_transaction_id: 'tx_1', last_failure_type: 'hard_declined', last_failure_message: 'the card has expired')

      info = described_class.info_for(braintree_subscription)

      expect(info).to include(can_pay_now: false, blocked_reason: 'hard_decline', failure_message: 'the card has expired')
    end

    it 'blocks during the cooldown and says when it ends' do
      PayNowLimit.claim!(subscription_id)

      info = described_class.info_for(braintree_subscription)

      expect(info[:blocked_reason]).to eq('cooldown')
      expect(info[:next_at]).to be_within(5.seconds).of(1.hour.from_now)
    end

    it 'offers nothing for a subscription that is not past due, without looking anything up' do
      braintree_subscription.instance_variable_set(:@status, ::Braintree::Subscription::Status::Active)
      expect(Invoice).not_to receive(:where)

      expect(described_class.info_for(braintree_subscription)).to eq(can_pay_now: false, blocked_reason: nil, next_at: nil, failure_message: nil)
    end

    it 'blocks a past-due subscription with no unpaid invoice' do
      invoice.update!(settled_at: Time.now)

      expect(described_class.info_for(braintree_subscription)).to include(can_pay_now: false, blocked_reason: 'unavailable')
    end
  end
end
