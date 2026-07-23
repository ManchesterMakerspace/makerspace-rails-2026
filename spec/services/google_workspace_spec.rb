require "rails_helper"

RSpec.describe Service::GoogleWorkspace do
  describe ".calendar_colors" do
    let(:calendar_service) { double("Google Calendar service") }

    before do
      allow(described_class).to receive(:calendar).and_return(calendar_service)
      allow(calendar_service).to receive(:respond_to?).with(:get_colors).and_return(false)
    end

    it "uses the generated client's singular get_color method" do
      definition = double(background: "#123456", foreground: "#ffffff")
      allow(calendar_service).to receive(:get_color).and_return(
        double(calendar: { "1" => definition })
      )

      expect(described_class.calendar_colors).to eq([
        {
          id: "1",
          name: "Cocoa",
          backgroundColor: "#123456",
          foregroundColor: "#ffffff"
        }
      ])
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
  end
end
