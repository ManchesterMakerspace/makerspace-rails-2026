require 'swagger_helper'

RSpec.describe 'Public Eventbrite events', type: :request do
  path '/eventbrite/events' do
    get 'Lists public upcoming and ongoing Eventbrite occurrences', operation: { servers: [{ url: '/' }] } do
      tags 'Eventbrite'
      operationId 'listPublicEventbriteEvents'
      security []
      produces 'application/json'
      description 'Defaults to HTML with the heading "Upcoming events". Each row shows the event title, local start time (e.g. Thursday Dec 3rd, 6PM), summary and ticket availability. HTML shows SOLD OUT for zero remaining tickets. Titles with a public URL open Eventbrite in a new tab. Use .html, .json, .xml or Accept. Returns listed, valid, unrestricted occurrences in allowed organizations, excluding draft and deleted events. Includes Open House. Results are ordered by start time.'
      parameter name: :max_days, in: :query, required: false, schema: { type: :integer, minimum: 1, default: 31 },
        description: 'Rolling window in days. Starts at the cutoff are excluded. Ongoing events are included.'
      parameter name: :min_tickets_remaining, in: :query, required: false, schema: { type: :integer, minimum: 0 },
        description: 'Inclusive minimum. Supplying it excludes unknown inventory.'
      parameter name: :name, in: :query, required: false, schema: { type: :string }, description: 'Include titles containing this literal text, ignoring case.'
      parameter name: :notname, in: :query, required: false, schema: { type: :string }, description: 'Exclude titles containing this literal text, ignoring case.'
      response '200', 'Matching public events in chronological order' do
        fields = %w[eventbrite_id name starts_at ends_at timezone summary venue_label status public_url image_url tickets_remaining]
        properties = fields.index_with { { type: :string, nullable: true } }.merge(
          'eventbrite_id' => { type: :string }, 'starts_at' => { type: :string, format: 'date-time' },
          'ends_at' => { type: :string, format: 'date-time', nullable: true },
          'tickets_remaining' => { type: :integer, nullable: true })
        schema type: :array, items: { type: :object, additionalProperties: false, required: fields, properties: properties }
        metadata[:response][:content] = { 'text/html' => { schema: { type: :string } }, 'application/xml' => { schema: { type: :string } } }
        it 'serves a public JSON entry at the root path by content negotiation' do |example|
          allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org'])
          EventbriteEvent.create!(organization_id: 'org', eventbrite_id: 'class', name: 'Workshop', status: 'live', listed: true, starts_at: 1.day.from_now)
          get '/eventbrite/events', headers: { 'Accept' => 'application/json' }
          assert_response_matches_metadata(example.metadata)
          expect(response.parsed_body.first.fetch('eventbrite_id')).to eq('class')
        end
      end
      response '400', 'Invalid filter' do
        schema type: :object, required: ['error'], properties: { error: { type: :string } }
        metadata[:response][:content] = { 'text/plain' => { schema: { type: :string } }, 'application/xml' => { schema: { type: :string } } }
        it 'rejects an invalid ticket minimum' do |example|
          get '/eventbrite/events.json', params: { min_tickets_remaining: '-1' }
          assert_response_matches_metadata(example.metadata)
        end
      end
    end
  end
end
