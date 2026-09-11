require 'rails_helper'

RSpec.describe DocumentUploadJob, type: :job do
  before do
    allow(Service::SlackConnector).to receive(:send_slack_message)
    allow(Service::AuditLogger).to receive(:log)
    allow(MemberMailer).to receive(:send_document).and_return(double(deliver_later: true))
  end

  describe '#perform' do
    it 'sends the document mailer when the upload is verified in Drive' do
      member = create(:member)
      allow(Service::GoogleDrive).to receive(:upload_document).and_return('pdf-bytes')
      allow(Service::GoogleDrive).to receive(:document_uploaded?).and_return(true)

      described_class.new.perform('signature-data', 'member_contract', member.id.as_json)

      expect(MemberMailer).to have_received(:send_document).with('member_contract', member.id.as_json, 'pdf-bytes')
      expect(Service::SlackConnector).not_to have_received(:send_slack_message)
    end

    it 'raises when the upload reports success but the file cannot be found afterward' do
      member = create(:member)
      allow(Service::GoogleDrive).to receive(:upload_document).and_return('pdf-bytes')
      allow(Service::GoogleDrive).to receive(:document_uploaded?).and_return(false)

      expect {
        described_class.new.perform('signature-data', 'member_contract', member.id.as_json)
      }.to raise_error(Error::Google::Upload)

      expect(MemberMailer).not_to have_received(:send_document)
    end

    it 'lets a genuine upload error from Drive propagate the same way' do
      member = create(:member)
      allow(Service::GoogleDrive).to receive(:upload_document).and_raise(Error::Google::Upload.new)

      expect {
        described_class.new.perform('signature-data', 'member_contract', member.id.as_json)
      }.to raise_error(Error::Google::Upload)
    end
  end

  describe '#report_upload_failure (final-failure alerting, invoked once retries are exhausted)' do
    it 'alerts Slack, writes an audit log entry, and rolls back the signed date for a member contract' do
      member = create(:member, member_contract_signed_date: Date.today)
      error = Error::Google::Upload.new('boom')

      described_class.new.send(:report_upload_failure, 'member_contract', member.id.as_json, error)

      expect(Service::SlackConnector).to have_received(:send_slack_message).with(
        a_string_matching(/#{Regexp.escape(member.fullname)}.*member_contract.*boom/)
      )
      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(
          event_type: 'document_upload_failed',
          resource_type: 'Member',
          resource_id: member.id.as_json,
          subject: member
        )
      )
      expect(member.reload.member_contract_signed_date).to be_nil
    end

    it 'alerts Slack, writes an audit log entry, and rolls back contract_on_file for a rental agreement' do
      rental = create(:rental, contract_signed_date: Date.today)
      error = Error::Google::Upload.new('boom')

      described_class.new.send(:report_upload_failure, 'rental_agreement', rental.id.as_json, error)

      expect(Service::AuditLogger).to have_received(:log).with(
        hash_including(
          event_type: 'document_upload_failed',
          resource_type: 'Rental',
          resource_id: rental.id.as_json,
          subject: rental.member
        )
      )
      expect(rental.reload.contract_signed_date).to be_nil
    end

    it 'does not raise if reporting itself fails, so the original failure is never masked' do
      member = create(:member)
      allow(Service::SlackConnector).to receive(:send_slack_message).and_raise('slack is down')

      expect {
        described_class.new.send(:report_upload_failure, 'member_contract', member.id.as_json, Error::Google::Upload.new)
      }.not_to raise_error
    end
  end
end
