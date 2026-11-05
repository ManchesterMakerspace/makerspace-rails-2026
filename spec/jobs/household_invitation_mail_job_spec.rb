require 'rails_helper'

RSpec.describe HouseholdInvitationMailJob do
  let(:invitation_id) { BSON::ObjectId.new.to_s }
  let(:token) { 'A-SECRET-TOKEN-that-must-not-be-reported-0123456' }

  it 'does not log its arguments' do
    expect(described_class.log_arguments).to be(false)
  end

  it 'sends the invitation email' do
    mail = double(deliver_now: true)
    expect(MemberMailer).to receive(:household_invitation).with(invitation_id, token).and_return(mail)

    described_class.perform_now(invitation_id, token)

    expect(mail).to have_received(:deliver_now)
  end

  context 'when sending fails' do
    before { allow(MemberMailer).to receive(:household_invitation).and_raise(Net::SMTPServerBusy, '421 try later') }

    it 'reports the error with the invitation id only, never the token, and does not re-raise' do
      reported = []
      allow(Service::ErrorReporter).to receive(:notify) { |error, **opts| reported << [error, opts] }

      expect { described_class.perform_now(invitation_id, token) }.not_to raise_error

      expect(reported.size).to eq(1)
      error, opts = reported.first
      expect(error).to be_a(Net::SMTPServerBusy)
      expect(opts[:context]).to eq(invitation_id: invitation_id, job: 'HouseholdInvitationMailJob')
      expect(opts.to_s).not_to include(token)
    end

    it 'does not hand Honeybadger the job arguments' do
      allow(Service::ErrorReporter).to receive(:notify)
      allow(Honeybadger).to receive(:notify) if defined?(Honeybadger)

      described_class.perform_now(invitation_id, token)

      expect(Honeybadger).not_to have_received(:notify).with(anything, hash_including(:parameters)) if defined?(Honeybadger)
    end
  end
end
