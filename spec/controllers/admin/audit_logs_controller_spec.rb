require 'rails_helper'

RSpec.describe Admin::AuditLogsController, type: :controller do
  set_devise_mapping

  let(:admin)  { create(:member, role: 'admin') }
  let(:board)  { create(:member, role: 'board_member') }
  let(:rm)     { create(:member, role: 'resource_manager') }
  let(:member) { create(:member) }

  let!(:log1) do
    log = AuditLog.create!(
      log_type:      'member',
      event_type:    'member_updated',
      resource_type: 'Member',
      resource_id:   member.id,
      actor_id:      admin.id,
      actor_name:    admin.fullname,
      subject_id:    member.id,
      subject_name:  member.fullname,
      slack_message: 'Member Updated by Admin on Jane Smith\'s Member'
    )
    log.set(created_at: 2.days.ago)
    log.reload
  end

  let!(:log2) do
    log = AuditLog.create!(
      log_type:      'portal',
      event_type:    'portal_setting_changed',
      resource_type: 'SystemConfig',
      resource_id:   BSON::ObjectId.new,
      actor_id:      board.id,
      actor_name:    board.fullname,
      slack_message: 'Portal Setting Changed by Board on SystemConfig'
    )
    log.set(created_at: 1.day.ago)
    log.reload
  end

  describe 'GET #index' do
    context 'as admin' do
      before { sign_in admin }

      it 'returns all logs' do
        get :index, format: :json
        expect(response).to have_http_status(:ok)
        parsed = JSON.parse(response.body)
        expect(parsed.length).to eq(2)
      end

      it 'filters by log_type' do
        get :index, params: { log_type: 'portal' }, format: :json
        parsed = JSON.parse(response.body)
        expect(parsed.length).to eq(1)
        expect(parsed.first['eventType']).to eq('portal_setting_changed')
      end

      it 'filters by event_type' do
        get :index, params: { event_type: 'member_updated' }, format: :json
        parsed = JSON.parse(response.body)
        expect(parsed.length).to eq(1)
        expect(parsed.first['logType']).to eq('member')
      end

      it 'filters by actor_id' do
        get :index, params: { actor_id: admin.id.to_s }, format: :json
        parsed = JSON.parse(response.body)
        expect(parsed.length).to eq(1)
        expect(parsed.first['actorName']).to eq(admin.fullname)
      end

      it 'filters by subject_id' do
        get :index, params: { subject_id: member.id.to_s }, format: :json
        parsed = JSON.parse(response.body)
        expect(parsed.length).to eq(1)
      end

      it 'filters by from_date' do
        get :index, params: { from_date: 1.5.days.ago.to_s }, format: :json
        parsed = JSON.parse(response.body)
        expect(parsed.length).to eq(1)
        expect(parsed.first['eventType']).to eq('portal_setting_changed')
      end

      it 'returns logs ordered newest first' do
        get :index, format: :json
        parsed = JSON.parse(response.body)
        dates = parsed.map { |l| Time.parse(l['createdAt']) }
        expect(dates).to eq(dates.sort.reverse)
      end

      it 'paginates results and reports the unpaginated total via the total-items header' do
        stub_const('FastQuery::ITEMS_PER_PAGE', 1)

        get :index, params: { page_num: 0 }, format: :json
        expect(response.headers['total-items'].to_s).to eq('2')
        first_page = JSON.parse(response.body)
        expect(first_page.length).to eq(1)
        expect(first_page.first['eventType']).to eq('portal_setting_changed')

        get :index, params: { page_num: 1 }, format: :json
        second_page = JSON.parse(response.body)
        expect(second_page.length).to eq(1)
        expect(second_page.first['eventType']).to eq('member_updated')
      end

      describe 'category filter' do
        def add_log(log_type, event_type)
          AuditLog.create!(log_type: log_type, event_type: event_type, resource_type: 'Member',
                           resource_id: member.id, slack_message: event_type)
        end

        before do
          add_log('member', 'system_email_sent')
          add_log('slack', 'slack_message_sent')
          add_log('member', 'invoice_settled')
          add_log('member', 'brand_new_event')
        end

        def event_types_for(category)
          get :index, params: { category: category }, format: :json
          JSON.parse(response.body).map { |log| log['eventType'] }
        end

        it 'returns one category, using the event type' do
          expect(event_types_for('email')).to eq(['system_email_sent'])
          expect(event_types_for('slack')).to eq(['slack_message_sent'])
          expect(event_types_for('billing')).to eq(['invoice_settled'])
          expect(event_types_for('members')).to eq(['member_updated'])
          expect(event_types_for('settings')).to eq(['portal_setting_changed'])
        end

        it 'puts unmapped event types in Other so nothing drops out of view' do
          expect(event_types_for('other')).to eq(['brand_new_event'])
        end

        it 'leaves Slack messages out of "all except Slack", and includes them in All' do
          expect(event_types_for('all_except_slack')).not_to include('slack_message_sent')
          expect(event_types_for('all_except_slack').size).to eq(5)
          expect(event_types_for('all').size).to eq(6)
          expect(event_types_for('').size).to eq(6)
        end

        it 'returns each entry with its category' do
          get :index, params: { category: 'billing' }, format: :json
          expect(JSON.parse(response.body).first['category']).to eq('billing')
        end

        it 'rejects an unknown category' do
          get :index, params: { category: 'nonsense' }, format: :json
          expect(response).to have_http_status(:unprocessable_content)
        end
      end
    end

    describe 'GET #filters' do
      it 'lists the categories and the event types present in the log, each with its category' do
        sign_in board
        get :filters, format: :json
        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body['categories'].first).to eq('value' => 'all_except_slack', 'label' => 'All except Slack messages')
        expect(body['categories'].map { |c| c['value'] }).to include('all', 'email', 'slack', 'settings', 'other')
        expect(body['eventTypes']).to eq([
          { 'value' => 'member_updated', 'category' => 'members' },
          { 'value' => 'portal_setting_changed', 'category' => 'settings' }
        ])
      end

      it 'is forbidden to a resource manager' do
        sign_in rm
        get :filters, format: :json
        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'as board member' do
      before { sign_in board }

      it 'is permitted' do
        get :index, format: :json
        expect(response).to have_http_status(:ok)
      end
    end

    context 'as resource manager' do
      before { sign_in rm }

      it 'is forbidden' do
        get :index, format: :json
        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'as regular member' do
      before { sign_in member }

      it 'is forbidden' do
        get :index, format: :json
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
