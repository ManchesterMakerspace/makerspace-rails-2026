require "rails_helper"

RSpec.describe RentalMailer, type: :mailer do
  let(:member) { create(:member, :current, firstname: "Pat") }
  let(:rental) { create(:rental, member: member, number: "BS-Tote-3", description: "Black Tote") }

  describe "#membership_lapsed" do
    it "tells the member the rental is still active and how to cancel it, with the wiki link" do
      message = described_class.membership_lapsed(member.id.to_s, "expired", [rental.id.to_s]).deliver_now
      body = message.body.to_s

      expect(message.perform_deliveries).to be(true)
      expect(message.to).to eq([member.email])
      expect(message.subject).to include("Still Have a Rental")
      expect(body).to include("Your membership has expired", "BS-Tote-3 (Black Tote)", "keeps billing", "Cancel Rental", "board member confirms", RentalLapseNotifier::WIKI_URL, "/members/#{member.id}")
      expect(body).to include("renew your membership first")
    end

    it "does not offer renewal when the membership was revoked or suspended" do
      body = described_class.membership_lapsed(member.id.to_s, "revoked", [rental.id.to_s]).body.to_s

      expect(body).to include("Your membership was revoked", "BS-Tote-3")
      expect(body).not_to include("renew your membership first")
    end

    it "skips rentals that are no longer active" do
      rental.update_attributes!(status: "vacating")

      expect(described_class.membership_lapsed(member.id.to_s, "expired", [rental.id.to_s]).body.to_s).not_to include("BS-Tote-3")
    end
  end
end
