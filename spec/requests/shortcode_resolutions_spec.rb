require "rails_helper"

RSpec.describe "Public shortcode resolution", type: :request do
  let!(:shop) { create(:shop) }
  let!(:tool) { create(:tool, shop: shop) }
  let(:target) { "/tools/#{tool.id}/request-checkout" }
  let(:code) { "23456789AB" }

  before do
    allow(ShortUrl).to receive(:base_url).and_return("https://members.example.org")
    allow(REDIS).to receive(:get).and_return(nil)
    allow(REDIS).to receive(:set)
    Shortcode.create!(code: code, target_url: target)
  end

  it "rechecks the visibility of a cached destination" do
    allow(REDIS).to receive(:get).and_return(target)
    tool.update!(disabled: true)
    get "/api/shortcodes/#{code}"
    expect(response.status).to eq(404)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "rejects invalid and unknown codes without caching their errors" do
    ["bad", "ZZZZZZZZZZ", code.downcase].each do |invalid|
      get "/api/shortcodes/#{invalid}"
      expect(response.status).to eq(404)
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  it "fails closed for an invalid stored target" do
    allow(ShortUrl).to receive(:resolve).and_return("https://members.example.org/admin")
    get "/api/shortcodes/#{code}"
    expect(response.status).to eq(404)
  end
end
