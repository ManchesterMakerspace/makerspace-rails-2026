require 'swagger_helper'

RSpec.describe 'Member Home API', type: :request do
  before { allow(REDIS).to receive(:set).and_return(true) }
  path '/home' do
    get 'Gets the current member landing page data' do
      tags 'Members'
      operationId 'getHome'
      produces 'application/json'
      description 'Requires a member session and completed TOTP challenge. Returns only the current member, confirmed Slack acceptance and up to 10 eligible, in-service safety checkouts (Orientation first). Does not initiate provisioning.'

      response '200', 'current member home data' do
        schema type: :object, required: %w[member slack availableCheckouts], properties: {
          member: { '$ref' => '#/components/schemas/Member' },
          slack: {
            type: :object, required: %w[accepted newMembersChannelUrl], properties: {
              accepted: { type: :boolean },
              newMembersChannelUrl: { type: :string, nullable: true, format: :uri }
            }
          },
          availableCheckouts: {
            type: :array, maxItems: 10, items: {
              type: :object, required: %w[id name shopName requestorAnnotation], properties: {
                id: { type: :string }, name: { type: :string }, shopName: { type: :string },
                requestorAnnotation: { type: :string, nullable: true }
              }
            }
          }
        }
        let(:member) { create(:member, status: 'pending', expirationTime: nil) }
        let!(:orientation) { create(:tool, name: 'Orientation', allow_pending: true, requestor_annotation: 'Bring ID') }
        before { sign_in member }
        run_test! do |response|
          expect(response.parsed_body.dig('member', 'id')).to eq(member.id.to_s)
          expect(response.parsed_body.fetch('availableCheckouts').first).to include('id' => orientation.id.to_s, 'requestorAnnotation' => 'Bring ID')
          expect(response.headers['Cache-Control']).to eq('private, no-store')
        end

        context 'an active board member opening their own Home' do
          let(:member) { create(:member, :current, role: 'board_member') }
          run_test!
        end
      end

      response '401', 'member authentication or TOTP challenge required' do
        run_test!
      end
    end
  end
end
