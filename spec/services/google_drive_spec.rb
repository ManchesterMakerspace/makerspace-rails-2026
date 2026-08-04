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
end
