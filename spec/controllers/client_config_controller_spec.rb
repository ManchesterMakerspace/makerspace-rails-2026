require "rails_helper"

RSpec.describe ClientConfigController, type: :controller do
  before { allow(CloudflareRails::Importer).to receive(:cloudflare_ips).and_return([]) }

  it "publishes APP_DOMAIN for public tool QR destinations" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("APP_DOMAIN").and_return(" portal.example.test ")
    get :index, format: :json
    expect(JSON.parse(response.body)["app_domain"]).to eq("portal.example.test")
  end

  it "publishes the normalized WIKI_URL for runtime clients" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("WIKI_URL")
      .and_return("https://wiki.example.test/")

    get :index, format: :json

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["wiki_url"])
      .to eq("https://wiki.example.test")
  end

  it "publishes native Firebase application configuration" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("FIREBASE_APP_ID").and_return("1:123:android:abc")
    allow(ENV).to receive(:[]).with("FIREBASE_WEB_CLIENT_ID").and_return("client.apps.googleusercontent.com")

    get :index, format: :json

    body = JSON.parse(response.body)
    expect(body["firebase_app_id"]).to eq("1:123:android:abc")
    expect(body["firebase_web_client_id"]).to eq("client.apps.googleusercontent.com")
  end
end
