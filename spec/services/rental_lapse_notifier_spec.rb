require "rails_helper"

# Messaging only (#276): nothing here cancels a rental, changes billing, or frees a space.
RSpec.describe RentalLapseNotifier do
  let(:member) { create(:member, :current, firstname: "Pat", lastname: "Tote") }
  let!(:rental) { create(:rental, member: member, number: "BS-Tote-3", description: "Black Tote", subscription_id: "sub-1") }
  let(:channel) { ::Service::SlackConnector.members_relations_channel }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
    allow(::Service::SlackConnector).to receive(:enque_message)
  end

  def link_slack(person = member)
    SlackUser.create!(member_id: person.id, slack_id: "U#{person.id.to_s[-6, 6]}", name: "pat")
  end

  describe ".active_rentals and .describe" do
    it "counts only rentals still marked active, not vacating or cancelled ones" do
      create(:rental, member: member, status: "vacating")
      create(:rental, member: member, status: "cancelled")

      expect(described_class.active_rentals(member).map(&:number)).to eq(["BS-Tote-3"])
    end

    it "names a space by its number and description" do
      expect(described_class.describe(rental)).to eq("BS-Tote-3 (Black Tote)")
      rental.description = nil
      expect(described_class.describe(rental)).to eq("BS-Tote-3")
    end
  end

  describe "the rental's staff note" do
    it "is added to the staff post, so staff see it before telling anyone to vacate, and never to the member" do
      rental.update_attributes!(notes: "contains facilities cleaning supplies")
      slack_user = link_slack

      described_class.notify_event(member, reason: :cancelled)

      expect(::Service::SlackConnector).to have_received(:enque_message).with(
        a_string_including("BS-Tote-3 (Black Tote)", "note: contains facilities cleaning supplies"), channel, anything
      )
      expect(::Service::SlackConnector).to have_received(:enque_message).with(
        satisfy { |text| !text.include?("cleaning supplies") }, slack_user.slack_id, anything
      )
      expect(described_class.weekly_line(member, reason: :expired)).to include("note: contains facilities cleaning supplies")
    end

    it "adds nothing when the rental has no note" do
      rental.update_attributes!(notes: "  ")
      expect(described_class.weekly_line(member, reason: :expired)).not_to include("note:")
    end

    it "shortens a long note" do
      rental.update_attributes!(notes: "x" * 300)

      line = described_class.weekly_line(member, reason: :expired)

      expect(line).to include("…")
      expect(line.length).to be < 500
    end

    # Rental sanitizes notes on save, so check the Slack escaping on an unsaved rental too.
    it "escapes Slack formatting and mentions" do
      note = described_class.note_for(Rental.new(notes: "<!channel> fish & *chips* `code`"))

      expect(note).to include("&lt;!channel&gt;", "&amp;")
      expect(note).not_to include("<!channel>", "*", "`")
    end
  end

  describe ".reason_for" do
    it "classifies why a membership counts as ended" do
      expect(described_class.reason_for(build(:member, status: "revoked"))).to eq(:revoked)
      expect(described_class.reason_for(build(:member, status: "suspended"))).to eq(:suspended)
      expect(described_class.reason_for(build(:member, status: "activeMember", expirationTime: 1.day.ago.to_i * 1000))).to eq(:expired)
      expect(described_class.reason_for(build(:member, status: "nonMember", expirationTime: 3.days.from_now.to_i * 1000))).to eq(:cancelled)
    end
  end

  describe ".notify_event" do
    it "posts to members relations, DMs a linked member, and emails them when a subscription is cancelled" do
      slack_user = link_slack

      expect(described_class.notify_event(member, reason: :cancelled)).to be(true)

      expect(::Service::SlackConnector).to have_received(:enque_message).with(
        a_string_including("Pat Tote", "membership subscription was cancelled", "still have an active rental", "BS-Tote-3 (Black Tote)", "still billing", "/members/#{member.id}"),
        channel, anything
      )
      expect(::Service::SlackConnector).to have_received(:enque_message).with(
        a_string_including("Hi Pat", "BS-Tote-3 (Black Tote)", "keeps billing", "renew your membership first", "Cancel Rental", "board member confirms", RentalLapseNotifier::WIKI_URL),
        slack_user.slack_id, anything
      )
      expect { described_class.notify_event(member, reason: :cancelled) }
        .to have_enqueued_mail(RentalMailer, :membership_lapsed).with(member.id.to_s, "cancelled", [rental.id.to_s])
    end

    it "emails a member who has no Slack account" do
      expect { described_class.notify_event(member, reason: :expired) }
        .to have_enqueued_mail(RentalMailer, :membership_lapsed)
      expect(::Service::SlackConnector).to have_received(:enque_message).once.with(anything, channel, anything)
    end

    %i[revoked suspended].each do |reason|
      it "tells staff a #{reason} member cannot be reached, and sends the member nothing" do
        link_slack

        expect { described_class.notify_event(member, reason: reason) }.not_to have_enqueued_mail(RentalMailer)

        expect(::Service::SlackConnector).to have_received(:enque_message).once.with(
          a_string_including("cannot be notified automatically", "contact them"), channel, anything
        )
      end
    end

    it "does nothing when the member has no active rental" do
      rental.update_attributes!(status: "vacating")

      expect(described_class.notify_event(member, reason: :cancelled)).to be(false)
      expect(::Service::SlackConnector).not_to have_received(:enque_message)
    end

    it "never raises into the revocation or cancellation that triggered it" do
      allow(::Service::SlackConnector).to receive(:enque_message).and_raise("redis down")

      expect(described_class.notify_event(member, reason: :cancelled)).to be(false)
    end
  end

  describe "the weekly review" do
    it "builds a staff line that says why and names the space" do
      line = described_class.weekly_line(member, reason: :expired)

      expect(line).to start_with("• ")
      expect(line).to include("Pat Tote", "membership has expired", "BS-Tote-3 (Black Tote)")
    end

    it "has no line for a member without an active rental" do
      rental.update_attributes!(status: "cancelled")
      expect(described_class.weekly_line(member, reason: :expired)).to be_nil
    end

    it "reaches a member with Slack by DM only, and one without by email only" do
      slack_user = link_slack

      expect { described_class.notify_member_weekly(member, reason: :expired) }.not_to have_enqueued_mail(RentalMailer)
      expect(::Service::SlackConnector).to have_received(:enque_message).with(a_string_including("has expired"), slack_user.slack_id, anything)

      slack_user.destroy
      expect { described_class.notify_member_weekly(member, reason: :expired) }.to have_enqueued_mail(RentalMailer, :membership_lapsed)
    end

    it "does not message a revoked member" do
      link_slack
      expect(described_class.notify_member_weekly(member, reason: :revoked)).to be(true)
      expect(::Service::SlackConnector).not_to have_received(:enque_message)
    end
  end
end
