require 'rails_helper'

RSpec.describe PaymentFailure do
  let(:member) { create(:member) }
  let(:invoice) { create(:invoice, member: member, subscription_id: 'sub_1', amount: 65.0) }

  def failed_transaction(id: 'tx_failed', status: 'processor_declined', type: 'soft_declined', code: '2001', text: 'Insufficient Funds', rejection: nil)
    double(
      id: id,
      status: status,
      processor_response_type: type,
      processor_response_code: code,
      processor_response_text: text,
      gateway_rejection_reason: rejection
    )
  end

  describe '.describe' do
    it 'says insufficient funds in plain words and keeps the raw response for board members' do
      details = described_class.describe(failed_transaction)

      expect(details).to eq(type: 'soft_declined', message: 'insufficient funds', code: '2001', text: 'Insufficient Funds')
    end

    it 'words an expired card and a bad card number' do
      expect(described_class.describe(failed_transaction(type: 'hard_declined', code: '2004'))[:message]).to eq('the card has expired')
      expect(described_class.describe(failed_transaction(type: 'hard_declined', code: '2007'))[:message]).to eq('the card number was not accepted')
    end

    it 'uses a generic bank decline for a processor code with no specific wording, without repeating the raw text' do
      details = described_class.describe(failed_transaction(type: 'hard_declined', code: '2014', text: 'Processor Declined - Fraud Suspected'))

      expect(details[:message]).to eq('your bank declined it, please contact your bank')
      expect(details[:message]).not_to match(/fraud/i)
    end

    it 'explains a gateway rejection for the security code, and says nothing for ones it cannot explain' do
      cvv = failed_transaction(status: 'gateway_rejected', type: nil, code: nil, text: nil, rejection: 'cvv')
      other = failed_transaction(status: 'gateway_rejected', type: nil, code: nil, text: nil, rejection: 'fraud')

      expect(described_class.describe(cvv)).to include(type: 'gateway_rejected', message: "the card's security code was not accepted")
      expect(described_class.describe(other)).to include(type: 'gateway_rejected', message: nil)
    end

    it 'gives no reason for a missing transaction rather than a guess' do
      expect(described_class.describe(nil)).to eq(type: nil, message: nil, code: nil, text: nil)
    end
  end

  describe '.record!' do
    it 'stores the transaction, the type and the member-facing wording on the invoice' do
      described_class.record!(invoice, failed_transaction(type: 'hard_declined', code: '2004'))

      invoice.reload
      expect(invoice.last_failed_transaction_id).to eq('tx_failed')
      expect(invoice.last_failure_type).to eq('hard_declined')
      expect(invoice.last_failure_message).to eq('the card has expired')
      expect(invoice.transaction_id).to be_nil
      expect(described_class.hard_decline?(invoice)).to be(true)
    end

    it 'stores unknown when nothing useful is said about the failure' do
      described_class.record!(invoice, failed_transaction(status: nil, type: nil, code: nil, text: nil))

      expect(invoice.reload.last_failure_type).to eq('unknown')
      expect(invoice.last_failure_message).to be_nil
    end
  end

  describe '.clear!' do
    it 'lifts a hard decline but keeps the failed transaction id' do
      described_class.record!(invoice, failed_transaction(type: 'hard_declined', code: '2004'))

      described_class.clear!(invoice)

      invoice.reload
      expect(described_class.hard_decline?(invoice)).to be(false)
      expect(invoice.last_failure_message).to be_nil
      expect(invoice.last_failed_transaction_id).to eq('tx_failed')
    end

    it 'does nothing without an invoice' do
      expect { described_class.clear!(nil) }.not_to raise_error
    end
  end

  describe '.ensure_recorded' do
    let(:gateway) { double(transaction: double) }

    before { invoice.update!(last_failed_transaction_id: 'tx_old') }

    it 'reads a failure from before reasons were stored from Braintree once, and saves it' do
      expect(gateway.transaction).to receive(:find).with('tx_old').once.and_return(failed_transaction(id: 'tx_old', code: '2001'))

      described_class.ensure_recorded(gateway, invoice)
      described_class.ensure_recorded(gateway, invoice.reload)

      expect(invoice.reload.last_failure_message).to eq('insufficient funds')
    end

    it 'does not read the transaction again after the member changed the payment method' do
      described_class.clear!(invoice)
      expect(gateway.transaction).not_to receive(:find)

      described_class.ensure_recorded(gateway, invoice.reload)

      expect(described_class.hard_decline?(invoice.reload)).to be(false)
    end

    it 'saves unknown when Braintree no longer has the transaction' do
      allow(gateway.transaction).to receive(:find).and_raise(::Braintree::NotFoundError)

      described_class.ensure_recorded(gateway, invoice)

      expect(invoice.reload.last_failure_type).to eq('unknown')
    end

    it 'leaves the invoice alone, to try again later, when Braintree cannot be reached' do
      allow(gateway.transaction).to receive(:find).and_raise(::Braintree::ServiceUnavailableError)

      described_class.ensure_recorded(gateway, invoice)

      expect(invoice.reload.last_failure_type).to be_nil
    end

    it 'does nothing for an invoice that never failed' do
      invoice.update!(last_failed_transaction_id: nil)
      expect(gateway).not_to receive(:transaction)

      described_class.ensure_recorded(gateway, invoice)
    end
  end

  describe '.board_summary' do
    it 'shows the decline type and the bank response' do
      summary = described_class.board_summary(described_class.describe(failed_transaction))

      expect(summary).to eq('soft declined, response 2001 (Insufficient Funds)')
    end
  end
end
