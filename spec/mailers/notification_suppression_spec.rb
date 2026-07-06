require 'rails_helper'

RSpec.describe 'notification suppression', type: :mailer do
  describe MarketingMailer do
    it 'does not send marketing mail to members with silence_emails enabled' do
      member = create(:member, silence_emails: true)

      message = described_class.request_signup(member.id.to_s).deliver_now

      expect(message.perform_deliveries).to be(false)
    end
  end

  describe MemberMailer do
    it 'sends non-marketing mail to members with silence_emails enabled' do
      member = create(:member, silence_emails: true)

      message = described_class.request_document('member_contract', member.id.to_s).deliver_now

      expect(message.perform_deliveries).to be(true)
    end

    it 'does not send non-marketing mail to revoked members' do
      member = create(:member, status: 'revoked', silence_emails: true)

      message = described_class.request_document('member_contract', member.id.to_s).deliver_now

      expect(message.perform_deliveries).to be(false)
    end

    it 'does not send non-marketing mail to secondary household members' do
      primary = create(:member)
      secondary = create(:member, groupName: primary.id.to_s)

      message = described_class.request_document('member_contract', secondary.id.to_s).deliver_now

      expect(message.perform_deliveries).to be(false)
    end

    it 'sends household disbanded mail to secondary household members' do
      primary = create(:member)
      secondary = create(:member, groupName: primary.id.to_s)

      message = described_class.household_disbanded(secondary.id.to_s, primary.id.to_s, false).deliver_now

      expect(message.perform_deliveries).to be(true)
    end
  end
end
