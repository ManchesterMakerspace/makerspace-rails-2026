require 'swagger_helper'
describe 'Eventbrite API', type: :request do
  before { allow(Service::MemberProvisioning).to receive(:invite_slack) }
  path '/signup_events' do
    get 'Lists public events eligible for signup attribution' do
      description 'Returns eligible imported events from every organization when EVENTBRITE_ORGANIZATION_IDS is blank; a configured allowlist restricts the results.'
      tags 'Eventbrite'
      operationId 'listSignupEvents'
      produces 'application/json'
      response '200', 'Eligible event summaries; no attendee data' do
        schema type: :array, items: { type: :object, required: %w[id name startsAt timezone], properties: {
          id: { type: :string }, name: { type: :string }, startsAt: { type: :string, format: 'date-time' }, timezone: { type: :string }
        } }
        before do
          %w[org-1 org-2].each do |org|
            EventbriteEvent.create!(organization_id: org, eventbrite_id: org, name: 'Workshop',
              starts_at: Time.current, timezone: 'America/New_York', status: 'live', listed: true)
          end
        end
        context 'without an organization allowlist' do
          before { allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return([]) }
          run_test! { |response| expect(JSON.parse(response.body).size).to eq(2) }
        end
        context 'with an organization allowlist' do
          before { allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org-1']) }
          run_test! { |response| expect(JSON.parse(response.body).size).to eq(1) }
        end
      end
    end
  end
  path '/signup_source' do
    put 'Completes the optional provider-onboarding source question for the signed-in member' do
      tags 'Eventbrite'
      operationId 'saveSignupSource'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :source, in: :body, schema: { type: :object, properties: {
        signupSource: { type: :string }, signupSourceDetail: { type: :string, maxLength: 100 }, signupEventbriteEventId: { type: :string }
      } }
      let(:source) { { signupSource: 'declined' } }
      response '200', 'Saved or already answered' do
        schema '$ref' => '#/components/schemas/Member'
        before { sign_in create(:member, signup_source_prompt_pending: true) }
        run_test!
      end
      response '401', 'Authentication required' do
        run_test!
      end
      response '422', 'Selected event unavailable; choose another answer or skip' do
        let(:source) { { signupSource: 'eventbrite', signupEventbriteEventId: BSON::ObjectId.new.to_s } }
        before { sign_in create(:member, signup_source_prompt_pending: true) }
        run_test!
      end
    end
  end
  %w[events orders attendees].each do |kind|
    path "/admin/eventbrite/#{kind}" do
      get "Lists restricted Eventbrite #{kind}" do
        description 'Sorted by Eastern event start date (earliest first), then buyer email (A–Z). Undated events sort last.' if kind == 'orders'
        description 'Sorted by attendee email (A–Z).' if kind == 'attendees'
        tags 'Eventbrite'
        operationId "listEventbrite#{kind.capitalize}"
        produces 'application/json'
        parameter name: :organization_id, in: :query, required: false,
          description: 'Filter by imported organization ID. A configured EVENTBRITE_ORGANIZATION_IDS allowlist restricts access; blank allows all imported organizations.',
          schema: { type: :string }
        %w[event_id status linked search pageNum].each do |name|
          parameter name: name.to_sym, in: :query, required: false, schema: { type: :string }
        end
        %i[from_date to_date].each do |name|
          parameter name: name, in: :query, required: false, schema: { type: :string, format: :date },
            description: 'Inclusive Eastern calendar date of the event start.'
        end
        parameter name: :exclude_open_house, in: :query, required: false, schema: { type: :boolean, default: false },
          description: 'Exclude events whose title contains Open House, ignoring case.'
        response '400', 'Invalid or reversed event date range' do
          let(:from_date) { '2026-02-30' }
          before { sign_in create(:member, role: 'resource_manager') }
          run_test!
        end
        response '200', 'Staff records with total-items pagination header' do
          header 'total-items', schema: { type: :integer }, description: 'Matching records before pagination.'
          schema type: :array, items: { '$ref' => '#/components/schemas/EventbriteRecord' }
          before do
            sign_in create(:member, role: 'resource_manager')
            model = { 'events' => EventbriteEvent, 'orders' => EventbriteOrder, 'attendees' => EventbriteAttendee }.fetch(kind)
            %w[org-1 org-2].each { |org| model.create!(organization_id: org, eventbrite_id: '1') }
          end
          context 'without an organization allowlist' do
            before { allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return([]) }
            run_test! { |response| expect(JSON.parse(response.body).size).to eq(2) }
          end
          context 'with an organization allowlist' do
            before { allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org-1']) }
            run_test! { |response| expect(JSON.parse(response.body).size).to eq(1) }
          end
        end
        response '403', 'Ordinary members cannot access imported records' do
          before { sign_in create(:member) }
          run_test!
        end
        response '401', 'Authentication required' do
          run_test!
        end
      end
    end
  end

  %w[events orders attendees].each do |kind|
    path "/admin/eventbrite/#{kind}/{id}" do
      get "Retrieves restricted Eventbrite #{kind} details" do
        tags 'Eventbrite'
        operationId "getEventbrite#{kind.capitalize}"
        produces 'application/json'
        parameter name: :id, in: :path, required: true, schema: { type: :string }
        let(:id) { model = { 'events' => EventbriteEvent, 'orders' => EventbriteOrder, 'attendees' => EventbriteAttendee }.fetch(kind); model.create!(organization_id: 'org-1', eventbrite_id: '1').id.to_s }
        response '200', 'Staff detail' do
          schema '$ref' => '#/components/schemas/EventbriteRecord'
          before do
            allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org-1'])
            sign_in create(:member, role: 'admin')
          end
          run_test!
          if kind == 'orders'
            context 'a historical refund with a provider changed time' do
              let(:id) do
                sync = EventbriteIntegration::Synchronizer.new(instance_double(EventbriteIntegration::Client))
                sync.import_event('id' => 'event', 'organization_id' => 'org-1', 'status' => 'live')
                sync.import_order({ 'id' => 'refunded', 'event_id' => 'event', 'status' => 'refunded', 'changed' => '2026-10-03T12:00:00Z' }).id.to_s
              end
              run_test! { |response| expect(Time.iso8601(JSON.parse(response.body)['refundedAt'])).to eq(Time.utc(2026, 10, 3, 12)) }
            end
            context 'a refund without a known provider time' do
              let(:id) do
                sync = EventbriteIntegration::Synchronizer.new(instance_double(EventbriteIntegration::Client))
                sync.import_event('id' => 'event', 'organization_id' => 'org-1', 'status' => 'live')
                sync.import_order({ 'id' => 'refunded', 'event_id' => 'event', 'status' => 'refunded' }).id.to_s
              end
              run_test! do |response|
                data = JSON.parse(response.body)
                expect(data['refundedAt']).to be_nil
                expect(data['invalidationReason']).to eq('refund')
                expect(data['invalidatedAt']).to be_present
              end
            end
          end
        end
        response '403', 'Forbidden' do
          before { sign_in create(:member) }
          run_test!
        end
      end
    end
  end
  %w[orders attendees].each do |kind|
    path "/admin/members/{member_id}/eventbrite/#{kind}" do
      get "Lists a member's linked Eventbrite #{kind}" do
        description 'Filters cannot widen member history. Member-scoped orders with linked=unlinked return an empty list because history derives from linked attendees.' if kind == 'orders'
        tags 'Eventbrite'
        operationId "listMemberEventbrite#{kind.capitalize}"
        produces 'application/json'
        parameter name: :member_id, in: :path, required: true, schema: { type: :string }
        parameter name: :pageNum, in: :query, required: false, schema: { type: :integer }
        let(:member_id) { create(:member).id.to_s }
        response '200', 'Staff member history' do
          schema type: :array, items: { '$ref' => '#/components/schemas/EventbriteRecord' }
          before do
            sign_in create(:member, role: 'board_member')
            if kind == 'orders'
              EventbriteOrder.create!(organization_id: 'org-1', eventbrite_id: 'own')
              EventbriteOrder.create!(organization_id: 'org-1', eventbrite_id: 'unrelated')
              EventbriteAttendee.create!(organization_id: 'org-1', eventbrite_id: 'attendee', order_id: 'own', member_id: member_id)
            end
          end
          run_test! do |response|
            if kind == 'orders'
              expect(JSON.parse(response.body).map { |record| record['eventbriteId'] }).to eq(['own'])
              get "/api/admin/members/#{member_id}/eventbrite/orders", params: { linked: 'unlinked' }
              expect(self.response).to have_http_status(:ok)
              expect(JSON.parse(self.response.body)).to eq([])
              expect(self.response.headers['total-items'].to_s).to eq('0')
            end
          end
        end
        response '403', 'Ordinary members cannot read own history' do
          before { sign_in Member.find(member_id) }
          run_test!
        end
      end
    end
  end
end

describe 'Eventbrite configured webhook', type: :request do
  # This rswag version ignores path-level server overrides when building requests.
  before { allow_any_instance_of(Rswag::Specs::RequestFactory).to receive(:base_path_from_servers).and_return('') }
  around do |example|
    keys = %w[EVENTBRITE_WEBHOOK_PATH EVENTBRITE_API_KEY EVENTBRITE_ORGANIZATION_IDS]
    old = keys.to_h { |key| [key, ENV[key]] }
    ENV['EVENTBRITE_WEBHOOK_PATH'] = '/eventbrite-example/00000000000000000000000000000000'
    ENV['EVENTBRITE_API_KEY'] = 'test-only'
    ENV['EVENTBRITE_ORGANIZATION_IDS'] = 'org-1'
    Rails.application.reload_routes!
    example.run
  ensure
    old.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    Rails.application.reload_routes!
  end
  path '/eventbrite-example/00000000000000000000000000000000', servers: [{ url: 'https://example.invalid' }] do
    post 'Accepts Eventbrite notifications at the configured private URL (this is a nonsecret example only)' do
      tags 'Eventbrite'
      operationId 'receiveEventbriteWebhook'
      consumes 'application/json'
      parameter name: :notification, in: :body, schema: { type: :object, properties: {
        api_url: { type: :string }, config: { type: :object, properties: { action: { type: :string } } }
      } }
      before { allow(EventbriteDeliveryJob).to receive(:perform_later) }
      response '202', 'Persisted before acknowledgement' do
        let(:notification) { { api_url: 'https://www.eventbriteapi.com/v3/orders/1/', config: { action: 'order.placed' } } }
        run_test!
      end
      response '200', 'Dashboard test acknowledged' do
        let(:notification) { { config: { action: 'test' } } }
        run_test!
      end
      response '400', 'Invalid resource pointer' do
        let(:notification) { { api_url: 'https://example.com/orders/1/' } }
        run_test!
      end
      response '503', 'Storage unavailable; Eventbrite should retry' do
        let(:notification) { { api_url: 'https://www.eventbriteapi.com/v3/orders/1/' } }
        before { allow(EventbriteWebhookDelivery).to receive(:create!).and_raise(Mongo::Error) }
        run_test!
      end
    end
  end
end
