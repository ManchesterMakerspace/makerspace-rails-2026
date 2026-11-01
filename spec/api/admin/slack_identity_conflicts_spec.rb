require 'swagger_helper'

describe 'Slack identity conflicts API', type: :request do
  let(:admin) { create(:member, :admin) }
  let(:conflict) do
    { slack_id: 'UNEW', slack_name: 'New', slack_email: 'new@example.com', member_id: 'abc', member_name: 'Test Member',
      conflicting_slack_id: 'ULINKED', conflicting_slack_name: 'Linked', conflicting_slack_email: 'linked@example.com' }
  end

  before do
    sign_in admin
    allow(Service::SlackUserSync).to receive(:detect_conflicts_for_page).and_return([[conflict], live_check])
    allow(Service::SlackUserSync).to receive(:live_scan_progress)
      .and_return(checked: 400, estimated_total: 1400, waiting_seconds: 0)
  end

  let(:live_check) { :fresh }

  path '/admin/slack_identity_conflicts' do
    get 'Lists Slack accounts that cannot be linked because the member already has another' do
      tags 'Slack identity conflicts'
      operationId 'adminListSlackIdentityConflicts'
      description 'The live check of Slack runs in pieces, one per request. While live_check is "scanning" the ' \
                  'conflicts found so far are returned with progress, and the caller asks again until it is ' \
                  'fresh. scan_size is the slack_conflict_scan_size setting: how many Slack accounts one piece checks.'
      security [sessionAuth: []]
      produces 'application/json'

      response '200', 'Conflicts and how the live check of Slack is going' do
        schema type: :object, required: %w[conflicts live_check scan_size], properties: {
          conflicts: { type: :array, items: { type: :object, properties: {
            slack_id: { type: :string }, slack_name: { type: :string }, slack_email: { type: :string },
            member_id: { type: :string }, member_name: { type: :string },
            conflicting_slack_id: { type: :string }, conflicting_slack_name: { type: :string },
            conflicting_slack_email: { type: :string }
          } } },
          live_check: { type: :string, enum: %w[fresh cached scanning unavailable],
                        description: 'fresh: a check just finished. cached: a check from the last few minutes. scanning: a check is under way. unavailable: it failed repeatedly, so only conflicts saved earlier are listed.' },
          scan_size: { type: :integer, minimum: 10, maximum: 500, default: 200,
                       description: 'Slack accounts one piece of the check looks at.' },
          progress: { type: :object, description: 'Only while live_check is scanning.', properties: {
            checked: { type: :integer },
            estimated_total: { type: :integer, nullable: true, description: 'From the last finished check; null until one has finished.' },
            waiting_seconds: { type: :integer, description: 'Seconds Slack asked us to wait before the next piece.' }
          } }
        }

        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['live_check']).to eq('fresh')
          expect(body['scan_size']).to eq(200)
          expect(body['conflicts'].first).to include('slack_id' => 'UNEW')
          expect(body).not_to have_key('progress')
        end

        context 'while the check is still under way' do
          let(:live_check) { :scanning }

          run_test! do |response|
            body = JSON.parse(response.body)
            expect(body['live_check']).to eq('scanning')
            expect(body['progress']).to eq('checked' => 400, 'estimated_total' => 1400, 'waiting_seconds' => 0)
          end
        end

        context 'with a saved scan size' do
          before { SystemConfig.set(SystemConfig::SLACK_CONFLICT_SCAN_SIZE, '40') }
          after { SystemConfig.where(key: SystemConfig::SLACK_CONFLICT_SCAN_SIZE).delete_all }

          run_test! { |response| expect(JSON.parse(response.body)['scan_size']).to eq(40) }
        end
      end

      response '403', 'Not an admin or board member' do
        before { sign_in create(:member) }

        run_test!
      end
    end
  end
end
