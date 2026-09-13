require 'swagger_helper'

RSpec.describe 'Fix tickets', type: :request do
  let(:member) { create(:member, :current) }
  let(:id) { FixTicketService.create!(actor: member, attributes: { title: 'Drill', description: 'Switch failed', category: 'broken', submission_key: SecureRandom.uuid }).id.to_s }
  before do
    ActiveJob::Base.queue_adapter = :test
    allow(REDIS).to receive(:set).and_return(true)
    allow(REDIS).to receive(:eval).and_return(1)
    sign_in member
  end
  path '/fix_tickets' do
    get 'List authorized repair tickets' do
      tags 'Fix tickets'
      security [sessionAuth: []]
      produces 'application/json'
      parameter name: :mode, in: :query, required: false, schema: { type: :string, enum: %w[all mine assigned queue public] }
      parameter name: :statuses, in: :query, required: false, schema: { type: :array, items: { type: :string, enum: FixTicket::STATUSES } }, style: :form, explode: true
      %w[shop_id tool_id priority category confirmation assignee_id sort direction].each { |name| parameter name: name, in: :query, required: false, schema: { type: :string } }
      %w[page page_size].each { |name| parameter name: name, in: :query, required: false, schema: { type: :integer } }
      response '200', 'Scoped, filtered, sorted page; public-only readers require current membership' do
        schema '$ref' => '#/components/schemas/FixTicketPage'
        run_test!
      end
      response '401', 'A signed-in member session is required' do
        schema '$ref' => '#/components/schemas/FixError'
        before { sign_out member }
        run_test!
      end
    end
    post 'Submit a report (activeMember and future expiration; cap enforced)' do
      tags 'Fix tickets'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :submission, in: :body, schema: {
        type: :object, required: %w[title description category submission_key], additionalProperties: false,
        properties: { title: { type: :string, maxLength: 150, pattern: FixTicket::SAFE_NAME_PATTERN }, description: { type: :string, maxLength: 10000 },
          category: { type: :string, enum: FixTicket::CATEGORIES }, submission_key: { type: :string },
          shop_id: { type: :string, nullable: true }, tool_id: { type: :string, nullable: true }, uncatalogued_tool: { type: :string, pattern: "(?:#{FixTicket::SAFE_NAME_PATTERN})|^$" },
          priority: { type: :integer, minimum: 1, maximum: 10, nullable: true }, i_broke_it: { type: :boolean }, i_can_fix_it: { type: :boolean }, public_read_only: { type: :boolean } }
      }
      let(:submission) { { title: 'Drill', description: 'Failed switch', category: 'broken', submission_key: SecureRandom.uuid } }
      response('200', 'Created, or previously accepted idempotent submission') { schema '$ref' => '#/components/schemas/FixTicketDetail'; run_test!(requires_transactions: true) }
      response '503', 'MongoDB topology does not support atomic ticket writes' do
        schema '$ref' => '#/components/schemas/FixError'
        before do
          allow(FixTicket).to receive(:with_session).and_raise(
            Mongo::Error::TransactionsNotSupported.new('Transactions are not supported for the cluster: standalone topology')
          )
        end
        run_test! do |response|
          expect(JSON.parse(response.body)['error']).to include('single-node replica set', 'Transactions are not supported for the cluster: standalone topology')
          expect(FixTicket.count).to eq(0)
          expect(FixTicketEvent.count).to eq(0)
        end
      end
    end
  end
  path '/fix_tickets/catalog' do
    get 'Report catalog, creation capability, cap and current open count' do
      tags 'Fix tickets'
      security [sessionAuth: []]
      produces 'application/json'
      response('200', 'Catalog and capabilities') { schema '$ref' => '#/components/schemas/FixTicketCatalog'; run_test! }
    end
  end
  path '/fix_tickets/{id}' do
    parameter name: :id, in: :path, type: :string
    get 'Read a ticket and redacted history' do
      tags 'Fix tickets'
      security [sessionAuth: []]
      produces 'application/json'
      response('200', 'No reporter identity is included') { schema '$ref' => '#/components/schemas/FixTicketDetail'; run_test!(requires_transactions: true) }
    end
    %i[patch put].each do |verb|
    public_send(verb, 'Update authorized ticket fields; priority is immutable') do
      tags 'Fix tickets'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :update, in: :body, schema: { type: :object, properties: {
        revision: { type: :integer }, status: { type: :string, enum: FixTicket::STATUSES }, confirmation: { type: :string, enum: FixTicket::CONFIRMATIONS },
        note: { type: :string }, title: { type: :string, maxLength: 150, pattern: FixTicket::SAFE_NAME_PATTERN }, description: { type: :string }, category: { type: :string },
        shop_id: { type: :string, nullable: true }, tool_id: { type: :string, nullable: true }, uncatalogued_tool: { type: :string, pattern: "(?:#{FixTicket::SAFE_NAME_PATTERN})|^$" },
        public_read_only: { type: :boolean }, announce_to_slack: { type: :boolean }, announcement_note: { type: :string }, nominate_reward: { type: :boolean }
      } }
      let(:update) { { note: 'Additional details' } }
      response('200', 'Updated; operation-specific staff/assignee/reporter authorization applies') { schema '$ref' => '#/components/schemas/FixTicketDetail'; run_test!(requires_transactions: true) }
      response('503', 'MongoDB topology does not support atomic ticket writes') { schema '$ref' => '#/components/schemas/FixError' }
    end
    end
  end
  { notes: ['Append a note', { note: { type: :string } }], withdraw: ['Withdraw own nonterminal report', {}],
    assignments: ['Staff assignment or self-unassignment', { member_ids: { type: :array, items: { type: :string } }, unassign_self: { type: :boolean } }],
    bounty: ['Admin/board/relevant RM: create bounty and publish ticket atomically', { title: { type: :string }, description: { type: :string }, credit_value: { type: :number }, prerequisite_tool_ids: { type: :array, items: { type: :string } } }],
    reward: ['Independent authorized reviewer: approve/reject pending reporter point', { decision: { type: :string, enum: %w[approve reject] } }],
    reveal: ['Admin-only acknowledged reporter reveal; audit records ticket ID/title and acting admin, excluding reporter identity; no-store', { acknowledged: { type: :boolean } }],
    outage: ['Repair staff: independent tool availability', { out_of_service: { type: :boolean } }],
    retry_delivery: ['Repair staff: retry pending notifications', {}] }.each do |action, (title, properties)|
    path "/fix_tickets/{id}/#{action}" do
      parameter name: :id, in: :path, type: :string
      post title do
        tags 'Fix tickets'
        security [sessionAuth: []]
        consumes 'application/json'
        parameter name: :body, in: :body, schema: { type: :object, properties: properties }
        produces 'application/json'
        response '200', 'Action accepted; authorization and lifecycle validated server-side' do
          schema '$ref' => "#/components/schemas/#{ { reveal: 'FixReporterReveal', outage: 'FixOutageResult', retry_delivery: 'FixDeliveryQueued' }.fetch(action, 'FixTicketDetail') }"
          let(:member) { create(:member, :admin, :current) }
          let(:id) do
            owner = create(:member, :current)
            attributes = { title: 'Repair', description: 'Switch broken', category: 'broken', submission_key: SecureRandom.uuid }
            if action == :outage
              tool = create(:tool, shop: create(:shop))
              attributes.merge!(tool_id: tool.id.to_s, shop_id: tool.shop_id.to_s)
            end
            owner = member if action == :withdraw
            ticket = FixTicketService.create!(actor: owner, attributes: attributes)
            if action == :reward
              nominator = create(:member, :admin, :current)
              FixTicketService.update!(id: ticket.id, actor: nominator, attributes: { status: 'resolved', note: 'Fixed', nominate_reward: true })
            end
            ticket.id.to_s
          end
          let(:body) do
            case action
            when :notes then { note: 'Further details' }
            when :assignments then { member_ids: [member.id.to_s] }
            when :bounty then { title: 'Repair drill', description: 'Replace switch', credit_value: 1 }
            when :reward then { decision: 'reject' }
            when :reveal then { acknowledged: true }
            when :outage then { out_of_service: true }
            else {}
            end
          end
          run_test!(requires_transactions: true)
        end
        response '403', 'Caller lacks this action capability' do; schema '$ref' => '#/components/schemas/FixError'; end
        response '422', 'Validation, cap, revision, or lifecycle conflict' do; schema '$ref' => '#/components/schemas/FixError'; end
        unless %i[reveal outage retry_delivery].include?(action)
          response('503', 'MongoDB topology does not support atomic ticket writes') { schema '$ref' => '#/components/schemas/FixError' }
        end
        if action == :reveal
          response '503', 'Identity is withheld when the reveal audit cannot be saved' do
            schema '$ref' => '#/components/schemas/FixError'
            let(:member) { create(:member, :admin, :current) }
            let(:body) { { acknowledged: true } }
            before { allow(Service::AuditLogger).to receive(:log).and_return(nil) }
            run_test!(requires_transactions: true) do |response|
              expect(JSON.parse(response.body)).not_to have_key('name')
              expect(JSON.parse(response.body)).not_to have_key('id')
            end
          end
        end
      end
    end
  end
  path '/fix_tickets/{id}/assignee_options' do
    parameter name: :id, in: :path, type: :string
    get 'Repair staff: search eligible assignees' do
      tags 'Fix tickets'
      security [sessionAuth: []]
      parameter name: :search, in: :query, required: false, type: :string
      produces 'application/json'
      response('200', 'Up to fifty active unexpired members') { schema type: :array, items: { '$ref' => '#/components/schemas/FixPerson' }; let(:member) { create(:member, :admin, :current) }; run_test!(requires_transactions: true) }
    end
  end
  path '/tools/{id}/outage' do
    parameter name: :id, in: :path, type: :string
    post 'Repair staff: change out-of-service independently of hidden' do
      tags 'Tools'
      security [sessionAuth: []]
      consumes 'application/json'
      parameter name: :body, in: :body, schema: { type: :object, required: ['out_of_service'], properties: { out_of_service: { type: :boolean } } }
      produces 'application/json'
      response('200', 'Availability and affected reservations for review') do
        schema '$ref' => '#/components/schemas/FixOutageResult'
        let(:member) { create(:member, :admin, :current) }
        let(:id) { create(:tool, shop: create(:shop)).id.to_s }
        let(:body) { { out_of_service: true } }
        run_test!
      end
    end
  end
  path '/volunteer/tasks/{id}/detail' do
    parameter name: :id, in: :path, type: :string
    get 'Authenticated bounty detail including optional source ticket_id' do
      tags 'Volunteer'
      security [sessionAuth: []]
      produces 'application/json'
      response('200', 'Current member or authorized source-ticket viewer') do
        schema '$ref' => '#/components/schemas/FixBountyDetail'
        let(:id) { VolunteerTask.create!(title: 'Repair drill', description: 'Replace switch', credit_value: 1, created_by_id: member.id).id.to_s }
        run_test!
      end
    end
  end
  path '/admin/volunteer_tasks/{id}/cancel' do
    parameter name: :id, in: :path, type: :string
    post 'Cancel a volunteer task; linked claims must first be released or rejected' do
      tags 'Volunteer'
      security [sessionAuth: []]
      produces 'application/json'
      response '403', 'A claimed or pending ticket bounty must be released or rejected before cancellation' do
        let(:member) { create(:member, :admin, :current) }
        let(:id) do
          ticket = FixTicketService.create!(actor: member, attributes: { title: 'Repair', description: 'Broken', category: 'broken', submission_key: SecureRandom.uuid })
          FixTicketService.bounty!(id: ticket.id, actor: member, attributes: { title: 'Repair', description: 'Replace switch', credit_value: 1 })
          task = ticket.reload.bounty
          task.update!(status: 'claimed', claimed_by_id: member.id)
          task.id.to_s
        end
        before do
          allow_any_instance_of(Admin::VolunteerTasksController).to receive(:slack_alert)
          allow_any_instance_of(Admin::VolunteerTasksController).to receive(:honeybadger_notify)
        end
        run_test!(requires_transactions: true)
      end
    end
  end
  path '/slack/commands/fix' do
    post 'Open Fix tickets; Slack signature, workspace and linked member required', operation: { servers: [{ url: '/' }] } do
      tags 'Slack'
      consumes 'application/x-www-form-urlencoded'
      produces 'application/json'
      parameter name: :'X-Slack-Request-Timestamp', in: :header, required: true, schema: { type: :string }
      parameter name: :'X-Slack-Signature', in: :header, required: true, schema: { type: :string }
      parameter name: :payload, in: :body, required: true, schema: { type: :object,
        required: %w[team_id user_id trigger_id], properties: { text: { type: :string }, team_id: { type: :string }, user_id: { type: :string }, trigger_id: { type: :string } } }
      response('200', 'Private response; opens an authorized modal') do
        schema type: :object, properties: { response_type: { type: :string }, text: { type: :string } }, required: %w[response_type text]
        let(:'X-Slack-Request-Timestamp') { Time.now.to_i.to_s }
        let(:'X-Slack-Signature') { 'signature-tested-in-slack-request-specs' }
        let(:team_id) { 'T_TEST' }
        let(:user_id) { 'U_TEST' }
        let(:trigger_id) { 'trigger' }
        before do
          allow_any_instance_of(Slack::FixController).to receive(:verify_slack_signature)
          allow(FixSlack).to receive(:member!).and_return(member)
          allow(Service::SlackConnector).to receive(:open_modal)
        end
        it 'returns an ephemeral response from the root Slack route' do |example|
          post '/slack/commands/fix', params: { team_id: team_id, user_id: user_id, trigger_id: trigger_id }
          assert_response_matches_metadata(example.metadata)
        end
      end
    end
  end
end
