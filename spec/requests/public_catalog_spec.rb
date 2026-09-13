require "rails_helper"

RSpec.describe "Public catalog", type: :request do
  let!(:shop) { create(:shop, name: "Workshop") }
  let!(:tool) { create(:tool, shop: shop, name: "Saw <script>", description: "<b>Unsafe HTML</b>", notes: "SECRET", gdrive_id: "INTERNAL") }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  before { allow(Rails).to receive(:cache).and_return(cache) }

  it "uses exactly two projected reads per page, even on cache hits" do
    3.times { |n| create(:tool, shop: shop, name: "Tool #{n}") }
    commands = []
    subscriber = Object.new
    subscriber.define_singleton_method(:started) { |event| commands << event.command if %w[find aggregate].include?(event.command_name) }
    subscriber.define_singleton_method(:succeeded) { |_event| }
    subscriber.define_singleton_method(:failed) { |_event| }
    client = Mongoid.default_client
    client.subscribe(Mongo::Monitoring::COMMAND, subscriber)
    begin
      ["/shops/#{shop.id}/public.html", "/tools/#{tool.id}/public.html"].each do |path|
        2.times do
          commands.clear
          get path
          expect(response).to have_http_status(:ok)
          expect(commands.length).to eq(2)
          expect(commands).to all(include("find", "projection"))
          expect(commands).to all(satisfy { |command| command["projection"].keys.none? { |key| %w[notes gdrive_id users_channel].include?(key) } })
        end
      end
    ensure
      client.unsubscribe(Mongo::Monitoring::COMMAND, subscriber)
    end
  end

  it "projects public JSON and escapes public HTML without cookies" do
    get "/tools/#{tool.id}/public"
    expect(response.parsed_body.keys).to match_array(%w[id name description open out_of_service wiki_url shop])
    get "/tools/#{tool.id}/public.html"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("&lt;script&gt;", "&lt;b&gt;Unsafe HTML&lt;/b&gt;", "Request checkout")
    expect(response.body).not_to include("SECRET", "INTERNAL", "csrf")
    expect(response.headers["Set-Cookie"]).to be_nil
    expect(response.headers["Cache-Control"].split(", ")).to match_array(%w[public max-age=0 s-maxage=0 must-revalidate])
  end

  it "lists visible tools alphabetically, including open tools" do
    create(:tool, shop: shop, name: "Alpha", open: true)
    create(:tool, shop: shop, name: "Hidden", disabled: true)
    get "/shops/#{shop.id}/public"
    expect(response.parsed_body.fetch("tools").map { |t| t["name"] }).to eq(["Alpha", tool.name])
    get "/shops/#{shop.id}/public.html"
    expect(response.body).to include("No checkout required")
    expect(response.body).not_to include("Hidden")
  end

  it "uses the HTML cache for 30 minutes and content ETags" do
    expect(cache).to receive(:fetch).with(anything, expires_in: 30.minutes).at_least(:once).and_call_original
    get "/tools/#{tool.id}/public.html"
    etag = response.headers["ETag"]
    get "/tools/#{tool.id}/public.html", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_modified)
    tool.update!(description: "Changed")
    get "/tools/#{tool.id}/public.html", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Changed")
    expect(response.headers["ETag"]).not_to eq(etag)
    tool.update!(disabled: true)
    get "/tools/#{tool.id}/public.html", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_found)
    expect(response.headers["Cache-Control"]).to eq("no-store")
  end

  it "reflects moves and parent hiding immediately" do
    other = create(:shop, name: "Other")
    get "/shops/#{shop.id}/public.html"
    tool.update!(shop: other)
    get "/shops/#{shop.id}/public.html"
    expect(response.body).not_to include("Saw")
    get "/tools/#{tool.id}/public.html"
    expect(response.body).to include("Other")
    other.update!(disabled: true)
    get "/tools/#{tool.id}/public.html"
    expect(response).to have_http_status(:not_found)
  end

  it "reuses rendered HTML until the 30 minute expiry" do
    renders = 0
    allow_any_instance_of(PublicCatalogController).to receive(:render_to_string).and_wrap_original do |method, *args|
      renders += 1
      method.call(*args)
    end
    get "/tools/#{tool.id}/public.html"
    get "/tools/#{tool.id}/public.html"
    expect(renders).to eq(1)
    travel 31.minutes do
      get "/tools/#{tool.id}/public.html"
      expect(renders).to eq(2)
    end
  end

  it "renders when Redis fails" do
    allow(cache).to receive(:fetch).and_raise(IOError)
    get "/tools/#{tool.id}/public.html"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Request checkout")
  end

  it "returns indistinguishable missing, malformed and hidden responses" do
    tool.update!(disabled: true)
    signatures = ["invalid", BSON::ObjectId.new.to_s, tool.id.to_s].map do |id|
      get "/tools/#{id}/public.html"
      [response.status, response.body, response.headers.values_at("Content-Type", "Cache-Control", "ETag", "Set-Cookie")]
    end
    expect(signatures.uniq.length).to eq(1)
    expect(signatures.first[0]).to eq(404)
    expect(Nokogiri::HTML(signatures.first[1]).at_css("title").text).to eq("Workshops")
  end
end
