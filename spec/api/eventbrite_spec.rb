require 'swagger_helper'
describe 'Eventbrite API', type: :request do
  before { allow(Service::MemberProvisioning).to receive(:invite_slack) }
  path '/signup_events' do
    get 'Lists public events eligible for signup attribution' do
      tags 'Eventbrite'
      operationId 'listSignupEvents'
      produces 'application/json'
      response '200', 'Eligible event summaries; no attendee data' do
        schema type: :array, items: { type: :object, required: %w[id name startsAt timezone], properties: {
          id: { type: :string }, name: { type: :string }, startsAt: { type: :string, format: 'date-time' }, timezone: { type: :string }
        } }
        run_test!
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
        tags 'Eventbrite'
        operationId "listEventbrite#{kind.capitalize}"
        produces 'application/json'
        %w[organization_id event_id status linked search pageNum].each do |name|
          parameter name: name.to_sym, in: :query, required: false, schema: { type: :string }
        end
        response '200', 'Staff records with total-items pagination header' do
          schema type: :array, items: { '$ref' => '#/components/schemas/EventbriteRecord' }
          before { sign_in create(:member, role: 'resource_manager') }
          run_test!
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
        tags 'Eventbrite'
        operationId "listMemberEventbrite#{kind.capitalize}"
        produces 'application/json'
        parameter name: :member_id, in: :path, required: true, schema: { type: :string }
        parameter name: :pageNum, in: :query, required: false, schema: { type: :integer }
        let(:member_id) { create(:member).id.to_s }
        response '200', 'Staff member history' do
          schema type: :array, items: { '$ref' => '#/components/schemas/EventbriteRecord' }
          before { sign_in create(:member, role: 'board_member') }
          run_test!
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
