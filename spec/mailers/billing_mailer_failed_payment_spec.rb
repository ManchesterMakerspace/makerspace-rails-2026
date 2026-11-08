require 'rails_helper'

RSpec.describe BillingMailer, '#failed_payment' do
  let(:member) { create(:member) }
  let(:invoice) { create(:invoice, member: member, subscription_id: 'sub_1', plan_id: '33556') }

  def body_of(message)
    (message.html_part || message).body.decoded
  end

  it 'says why the charge failed and links to the portal to pay now' do
    message = described_class.failed_payment(member.email, invoice.id.to_s, 'processor_declined', 'insufficient funds').deliver_now

    expect(body_of(message)).to include('Reason: insufficient funds.')
    expect(body_of(message)).to match(/Pay now/)
    expect(body_of(message)).to include(Rails.configuration.x.app_base_url)
  end

  it 'adds no reason line when the reason is not known' do
    message = described_class.failed_payment(member.email, invoice.id.to_s, 'past_due').deliver_now

    expect(body_of(message)).not_to include('Reason:')
    expect(body_of(message)).to match(/Pay now/)
  end

  describe 'the editable template' do
    it 'accepts the failure_reason placeholder and fills it as a sentence' do
      template = '<p>{{member_name}} {{error_status}} {{failure_reason}}</p>'
      allow(::Service::EmailTemplate).to receive(:render).and_wrap_original do |original, name, variables, **options|
        expect(variables[:failure_reason]).to eq('Reason: the card has expired.')
        original.call(name, variables, **options)
      end
      allow(::Service::EmailTemplate).to receive(:cached_record).and_return('content' => template)

      described_class.failed_payment(member.email, invoice.id.to_s, 'processor_declined', 'the card has expired').deliver_now
    end

    it 'sends an empty failure_reason when unknown' do
      expect(::Service::EmailTemplate).to receive(:render) do |_name, variables, **_options|
        expect(variables[:failure_reason]).to eq('')
        nil
      end

      described_class.failed_payment(member.email, invoice.id.to_s, 'past_due').deliver_now
    end

    it 'lists failure_reason as a placeholder of the failed_payment template' do
      expect(::Service::EmailTemplate::TEMPLATE_DEFINITIONS[:failed_payment][:placeholders]).to include('failure_reason')
    end
  end
end
