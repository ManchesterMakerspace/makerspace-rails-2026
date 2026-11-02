require 'rails_helper'

RSpec.describe MemberMailer, type: :mailer do
  let(:member) { create(:member, firstname: 'Sam', email: 'sam@example.com') }

  # No Google Doc is configured in the test environment, so these exercise the built-in fallback text.
  describe '#fob_reminder' do
    subject(:mail) { described_class.fob_reminder(member.id.as_json, '2026-09-12') }

    it 'is addressed to the member with the fob subject' do
      expect(mail.to).to eq(['sam@example.com'])
      expect(mail.subject).to eq('Your Manchester Makerspace membership is paid. Come get your key fob')
    end

    it 'greets the member, names the payment date, and says when to come' do
      body = mail.body.decoded
      expect(body).to include('Hi Sam')
      expect(body).to include('September 12, 2026')
      expect(body).to include('Monday from 6 to 8pm')
      expect(body).to include('photo ID')
    end
  end

  describe '#signup_reminder' do
    subject(:mail) { described_class.signup_reminder(member.id.as_json) }

    it 'is addressed to the member with the finish-joining subject' do
      expect(mail.to).to eq(['sam@example.com'])
      expect(mail.subject).to eq('Finish joining Manchester Makerspace')
    end

    it 'invites them to choose a membership and come to an open house, without mentioning cash' do
      body = mail.body.decoded
      expect(body).to include('Hi Sam')
      expect(body).to include('choose a membership')
      expect(body).to include('Monday from 6 to 8pm')
      expect(body.downcase).not_to include('cash')
    end
  end
end
