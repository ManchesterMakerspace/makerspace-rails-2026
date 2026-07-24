require "rails_helper"

RSpec.describe Service::GoogleWorkspace do
  describe ".calendar_colors" do
    let(:calendar_service) { double("Google Calendar service") }

    before do
      allow(described_class).to receive(:calendar).and_return(calendar_service)
      allow(calendar_service).to receive(:respond_to?).with(:get_colors).and_return(false)
      allow(calendar_service).to receive(:get_color)
      allow(REDIS).to receive(:get).with(described_class::CALENDAR_COLOR_CACHE_KEY).and_return(nil)
      allow(REDIS).to receive(:set).and_return(true)
    end

    it "uses get_color and puts nearest key colors before 24 additional colors" do
      source_colors = described_class::FALLBACK_CALENDAR_COLORS.map do |color|
        color[:backgroundColor]
      end + 30.times.map { |index| format("#%06x", index * 7_919 % 0xffffff) }
      definitions = source_colors.each_with_index.to_h do |background, index|
        [
          (index + 1).to_s,
          double(background: background, foreground: "#ffffff")
        ]
      end
      allow(calendar_service).to receive(:get_color).and_return(
        double(calendar: definitions)
      )

      colors = described_class.calendar_colors

      expect(colors.first(11).map { |color| color[:name] }).to eq(
        %w[Black Red Blue Green Yellow Orange Brown Purple Gray Tan Teal]
      )
      expect(colors.length).to eq(35)
      expect(colors.map { |color| color[:id] }.uniq.length).to eq(35)
      expect(calendar_service).to have_received(:get_color).once
    end

    it "returns the named fallback palette when Google colors are unavailable" do
      allow(calendar_service).to receive(:get_color).and_raise(
        StandardError, "colors endpoint unavailable"
      )

      colors = described_class.calendar_colors

      expect(colors.map { |color| color[:name] }).to eq(
        %w[Black Red Blue Green Yellow Orange Brown Purple Gray Tan Teal]
      )
      expect(colors.first).to include(
        id: "1",
        backgroundColor: "#000000",
        foregroundColor: "#ffffff"
      )
    end

    it "uses Redis and appends an existing shop color missing from the selected list" do
      cached = {
        colors: [
          {
            id: "1", name: "Black",
            backgroundColor: "#000000", foregroundColor: "#ffffff"
          }
        ],
        allColors: [
          {
            id: "1", name: "Black",
            backgroundColor: "#000000", foregroundColor: "#ffffff"
          },
          {
            id: "42", name: "Legacy blue",
            backgroundColor: "#1234ff", foregroundColor: "#ffffff"
          }
        ]
      }
      allow(REDIS).to receive(:get).and_return(JSON.generate(cached))

      colors = described_class.calendar_colors(include_color_id: "42")

      expect(colors.last).to include(
        id: "42",
        name: "Legacy blue",
        backgroundColor: "#1234ff"
      )
      expect(calendar_service).not_to have_received(:get_color)
      expect(REDIS).to have_received(:set).with(
        described_class::CALENDAR_COLOR_CACHE_KEY,
        include('"id":"42"')
      )
    end
  end
end
