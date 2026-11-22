require "swagger_helper"

RSpec.describe "Shortcode resolution API", type: :request do
  path "/shortcodes/{code}" do
    get "Resolve a printed Makerspace short URL" do
      tags "Shortcodes"
      produces "application/json"
      security []
      parameter name: :code, in: :path, required: true,
                schema: { type: :string, pattern: "^[2-9A-Z]{10}$" }
      let(:code) { "23456789AB" }

      before do
        allow(ShortUrl).to receive(:base_url).and_return("https://members.example.org")
      end

      response "200", "Supported destination; authentication still applies at the destination" do
        header "Cache-Control", schema: { type: :string, enum: ["no-store"] }
        schema type: :object, additionalProperties: false,
               required: ["target_path"], properties: { target_path: { type: :string } }
        let(:tool) { create(:tool, shop: create(:shop)) }
        let(:target_path) { "/tools/#{tool.id}/request-checkout" }

        before do
          expect(ShortUrl).to receive(:resolve).with(code, origin: "https://members.example.org").and_call_original
          allow(REDIS).to receive(:get).and_call_original
          allow(REDIS).to receive(:get).with("#{ShortUrl::KEY_PREFIX}#{code}").and_return(nil)
          allow(REDIS).to receive(:set).and_call_original
          allow(REDIS).to receive(:set).with("#{ShortUrl::KEY_PREFIX}#{code}", target_path, ex: ShortUrl::TTL)
          Shortcode.create!(code: code, target_url: target_path)
        end

        run_test!("resolves without login but still requires login at the destination") do |resolution|
          expect(resolution.parsed_body).to eq("target_path" => target_path)
          expect(resolution.headers["Cache-Control"]).to eq("no-store")
          expect(resolution.headers["Set-Cookie"]).to be_nil

          get target_path
          expect(response).to redirect_to("/login?return_to=#{ERB::Util.url_encode(target_path)}")
        end
      end

      response "404", "Invalid or unknown code, or unavailable resource" do
        schema type: :object, required: ["error"], properties: { error: { type: :string } }
        before { allow(ShortUrl).to receive(:resolve).and_return(nil) }
        run_test!
      end

      response "503", "Resolver infrastructure unavailable" do
        schema type: :object, required: ["error"], properties: { error: { type: :string } }
        before { allow(ShortUrl).to receive(:resolve).and_raise(ShortUrl::Unavailable) }
        run_test! { |response| expect(response.headers["Cache-Control"]).to eq("no-store") }
      end
    end
  end
end
