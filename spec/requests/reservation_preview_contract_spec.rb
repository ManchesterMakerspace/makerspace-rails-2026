require "swagger_helper"
require "json-schema"

RSpec.describe "Reservation preview fee contract", type: :request do
  let(:member) { create(:member, :current) }
  let(:shop) { create(:shop, reservable: true, max_reservation_duration_hours: 24) }
  let(:schemas) do
    source = JSON.parse(RSpec.configuration.openapi_specs.values.first[:components][:schemas][:ReservationPreview].to_json)
    published = JSON.parse(File.read(Rails.root.join("swagger/v1/swagger.json"))).dig("components", "schemas", "ReservationPreview")
    expect(published).to eq(source)
    [source, published]
  end

  before do
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    ActiveJob::Base.queue_adapter = :test
    sign_in member
  end

  [false, true].each do |charged|
    it "validates a #{charged ? 'paid' : 'free'} preview against source and published schemas" do
      if charged
        option = InvoiceOption.create!(name: "Extended", amount: 10, quantity: 1, resource_class: "fee")
        shop.update!(duration_fees: [{ invoice_option_id: option.id.to_s, minimum_hours: 4, maximum_hours: 4 }])
      end
      start_at = 2.days.from_now.change(hour: 10, min: 0, sec: 0)
      input = { title: "Contract test", shop_id: shop.id.to_s, reservation_scope: "shop", tool_ids: [],
        start_at: start_at.iso8601, end_at: (start_at + 4.hours).iso8601 }
      post "/api/reservations/preview", params: input, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["eligible"]).to eq(true), body.inspect
      schemas.each { |schema| expect(JSON::Validator.fully_validate(schema, body)).to eq([]) }
      expect(body["feeTotal"]).to eq(charged ? 10 : 0)
      expect(body["feeLines"].length).to eq(charged ? 1 : 0)
      expect(body["feeConfirmation"]).to be_a(String)
      post "/api/reservations", params: input.merge(feeConfirmation: body.fetch("feeConfirmation")), as: :json
      expect(response).to have_http_status(:created), response.body
    end
  end
end
