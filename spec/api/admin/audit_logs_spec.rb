require 'swagger_helper'

describe 'Audit Log API', type: :request do
  let(:admin) { create(:member, :admin) }
  let(:board) { create(:member, :board_member) }
  let(:member) { create(:member) }

  audit_log_schema = {
    type: :object,
    properties: {
      id: { type: :string },
      logType: { type: :string, description: 'member, portal, or slack (a Slack message the portal sent)' },
      eventType: { type: :string },
      category: { type: :string, description: 'Derived from eventType; see GET /admin/audit_logs/filters' },
      actorId: { type: :string, nullable: true },
      actorName: { type: :string, nullable: true },
      subjectId: { type: :string, nullable: true },
      subjectName: { type: :string, nullable: true },
      resourceType: { type: :string },
      resourceId: { type: :string },
      fieldChanges: { type: :object, nullable: true },
      beforeSnapshot: { type: :object, nullable: true },
      afterSnapshot: { type: :object, nullable: true },
      slackChannel: { type: :string, nullable: true },
      slackMessage: { type: :string },
      slackPosted: { type: :boolean, nullable: true },
      ipAddress: { type: :string, nullable: true },
      createdAt: { type: :string, format: 'date-time' }
    },
    required: %w[id logType eventType category resourceType slackMessage createdAt]
  }

  before do
    AuditLog.create!(log_type: 'member', event_type: 'system_email_sent', resource_type: 'Member',
                     resource_id: member.id, subject_id: member.id, slack_message: 'Email sent')
    AuditLog.create!(log_type: 'slack', event_type: 'slack_message_sent', resource_type: 'SlackChannel',
                     resource_id: 'shop-woodworking', slack_channel: 'shop-woodworking', slack_posted: true,
                     slack_message: 'Bandsaw is out of service', after_snapshot: { 'source' => 'ShopAvailability' })
  end

  path '/admin/audit_logs' do
    get 'Lists audit log entries (admin or board)' do
      tags 'Audit Log'
      operationId 'adminListAuditLogs'
      produces 'application/json'
      parameter name: :category, in: :query, type: :string, required: false,
        description: 'all, all_except_slack, a category key from GET /admin/audit_logs/filters, or other. Omit (or all) for every entry.'
      parameter name: :logType, in: :query, type: :string, required: false
      parameter name: :eventType, in: :query, type: :string, required: false
      parameter name: :actorId, in: :query, type: :string, required: false
      parameter name: :subjectId, in: :query, type: :string, required: false
      parameter name: :fromDate, in: :query, type: :string, required: false
      parameter name: :toDate, in: :query, type: :string, required: false
      parameter name: :pageNum, in: :query, type: :integer, required: false

      response '200', 'entries in the category, newest first' do
        before { sign_in board }
        let(:category) { 'slack' }
        schema type: :array, items: audit_log_schema
        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body.map { |entry| entry['category'] }).to eq(['slack'])
          expect(body.first['slackMessage']).to eq('Bandsaw is out of service')
        end
      end

      response '422', 'unknown category' do
        before { sign_in admin }
        let(:category) { 'nonsense' }
        run_test!
      end

      response '403', 'not an admin or board member' do
        before { sign_in member }
        run_test!
      end
    end
  end

  path '/admin/audit_logs/filters' do
    get 'Lists the audit log filter choices: categories and the event types present' do
      tags 'Audit Log'
      operationId 'adminListAuditLogFilters'
      produces 'application/json'

      response '200', 'filter choices' do
        before { sign_in admin }
        schema type: :object,
          properties: {
            categories: { type: :array, items: { type: :object, properties: { value: { type: :string }, label: { type: :string } }, required: %w[value label] } },
            eventTypes: { type: :array, items: { type: :object, properties: { value: { type: :string }, category: { type: :string } }, required: %w[value category] } }
          },
          required: %w[categories eventTypes]
        run_test! do |response|
          body = JSON.parse(response.body)
          expect(body['eventTypes']).to include({ 'value' => 'slack_message_sent', 'category' => 'slack' })
        end
      end

      response '403', 'not an admin or board member' do
        before { sign_in member }
        run_test!
      end
    end
  end
end
