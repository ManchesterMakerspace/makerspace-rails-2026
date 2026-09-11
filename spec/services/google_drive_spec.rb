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

  describe '.expected_document_filename' do
    it "builds the filename from the resource's recorded signed date, not Time.now" do
      member = create(:member, member_contract_signed_date: Date.new(2020, 7, 18))

      expect(described_class.expected_document_filename(member, 'member_contract'))
        .to eq("#{member.fullname}_member_contract_07-18-2020.pdf")
    end

    it 'returns nil when the resource has no signed date yet' do
      member = create(:member, member_contract_signed_date: nil)

      expect(described_class.expected_document_filename(member, 'member_contract')).to be_nil
    end
  end

  describe '.document_uploaded?' do
    before do
      allow(described_class).to receive(:get_templates).and_return(member_contract: { folder_id: 'folder-1' })
    end

    it 'is true when a matching file exists in the configured folder' do
      member = create(:member, member_contract_signed_date: Date.new(2020, 7, 18))
      allow(described_class).to receive(:load_gdrive).and_return(double(list_files: double(files: [double(id: '1')])))

      expect(described_class.document_uploaded?(member, 'member_contract')).to be true
    end

    it 'is false when no matching file exists (e.g. the upload landed in the wrong folder)' do
      member = create(:member, member_contract_signed_date: Date.new(2020, 7, 18))
      allow(described_class).to receive(:load_gdrive).and_return(double(list_files: double(files: [])))

      expect(described_class.document_uploaded?(member, 'member_contract')).to be false
    end

    it 'is false when the resource has no signed date yet, without calling Drive at all' do
      member = create(:member, member_contract_signed_date: nil)
      allow(described_class).to receive(:load_gdrive)

      expect(described_class.document_uploaded?(member, 'member_contract')).to be false
      expect(described_class).not_to have_received(:load_gdrive)
    end
  end

  describe '.get_document' do
    before do
      allow(described_class).to receive(:get_templates).and_return(member_contract: { folder_id: 'folder-1' })
    end

    it 'raises NotFound when no file matches' do
      member = create(:member, member_contract_signed_date: Date.new(2020, 7, 18))
      allow(described_class).to receive(:load_gdrive).and_return(double(list_files: double(files: [])))

      expect { described_class.get_document(member, 'member_contract') }.to raise_error(Error::NotFound)
    end

    it 'downloads the matched file' do
      member = create(:member, member_contract_signed_date: Date.new(2020, 7, 18))
      matched_file = double(id: 'file-1', web_content_link: 'link')
      drive = double(list_files: double(files: [matched_file]))
      allow(drive).to receive(:get_file) { |_id, download_dest:| download_dest.write('pdf-bytes'); download_dest }
      allow(described_class).to receive(:load_gdrive).and_return(drive)

      result = described_class.get_document(member, 'member_contract')

      expect(File.read(result.path)).to eq('pdf-bytes')
    end
  end
end
