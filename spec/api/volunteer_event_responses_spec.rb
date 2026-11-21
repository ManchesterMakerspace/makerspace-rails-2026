require 'swagger_helper'

RSpec.describe 'Volunteer event write responses', type: :request do
  let(:member) { create(:member, :admin, :current) }
  let(:event) { VolunteerEvent.create!(title: 'Open house', credit_value: 1) }
  let(:id) { event.id.to_s }
  before { sign_in member }

  [['/admin/volunteer_events', :post], ['/admin/volunteer_events/{id}', :put], ['/admin/volunteer_events/{id}', :patch]].each do |endpoint, verb|
    path endpoint do
      parameter name: :id, in: :path, type: :string unless verb == :post
      public_send(verb, 'Save a volunteer event with a positive credit value and no upper credit cap') do
        tags 'Volunteer'
        security [sessionAuth: []]
        consumes 'application/json'
        produces 'application/json'
        parameter name: :body, in: :body, schema: {
          type: :object, properties: { title: { type: :string }, description: { type: :string }, credit_value: { type: :number, exclusiveMinimum: true, minimum: 0 },
            event_date: { type: :string, format: :date, nullable: true }, shop_id: { type: :string, nullable: true },
            prerequisite_tool_ids: { type: :array, items: { type: :string } } }
        }
        response '200', 'Saved event; event credits remain uncapped' do
          schema type: :object, required: %w[id title creditValue], properties: {
            id: { type: :string }, title: { type: :string }, creditValue: { type: :number }
          }
          let(:body) { { title: 'Open house', credit_value: 1000 } }
          run_test! { |response| expect(response.parsed_body['creditValue']).to eq(1000) }
        end
        response '422', 'Friendly event validation errors' do
          schema type: :object, required: %w[status error message errors], properties: {
            status: { type: :integer, enum: [422] }, error: { type: :string, enum: ['unprocessable_content'] },
            message: { type: :string }, errors: { type: :object, additionalProperties: { type: :array, items: { type: :string } } }
          }
          let(:body) { { title: 'Open house', credit_value: 0 } }
          run_test! do |response|
            expect(response.parsed_body['message']).to include('Credit value')
            expect(response.parsed_body.dig('errors', 'credit_value')).to be_present
          end
        end
      end
    end
  end
end
