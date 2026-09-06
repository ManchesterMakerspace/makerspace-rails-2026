require 'rails_helper'

RSpec.describe Service::GoogleDrive do
  describe '.sanitize_base64_signature' do
    it 'normalizes valid base64 signature data' do
      signature = Base64.encode64('signature-bytes')

      expect(described_class.sanitize_base64_signature(signature)).to eq(Base64.strict_encode64('signature-bytes'))
    end

    it 'rejects signature data that could inject HTML into the PDF template' do
      injected_signature = "' /><iframe src='http://169.254.169.254/latest/meta-data/'></iframe>"

      expect { described_class.sanitize_base64_signature(injected_signature) }
        .to raise_error(Error::UnprocessableEntity, 'Invalid signature')
    end
  end

  describe '.generate_document_string' do
    it 'resolves the documents/member_contract template instead of raising MissingTemplate' do
      member = create(:member)
      allow(described_class).to receive(:get_templates).and_return({ member_contract: {} })
      allow(WickedPdf).to receive(:new).and_return(double(pdf_from_string: 'pdf-bytes'))

      signature = Base64.strict_encode64('signature-bytes')
      result = described_class.generate_document_string(:member_contract, { member: member }, signature)

      expect(result).to eq('pdf-bytes')
    end
  end
end
