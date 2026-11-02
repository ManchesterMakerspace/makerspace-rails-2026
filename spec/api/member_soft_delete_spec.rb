require 'swagger_helper'

RSpec.describe 'Member soft delete and restore', type: :request do
  let(:admin) { create(:member, :admin, :current) }
  let(:target) { create(:member, status: 'inactive', expirationTime: nil) }
  let(:id) { target.id.to_s }
  let(:clean_removal) do
    { slack: { status: :not_found }, gdrive_resources: { status: :not_found }, gdrive_transfer_share: { status: :not_found } }
  end

  before do
    allow(Service::AuditLogger).to receive(:log)
    # The real teardown would call Slack, Google and Braintree.
    allow(Service::MemberAccess).to receive(:full_deprovision).and_return(clean_removal)
    sign_in admin
  end

  path '/admin/members/{id}/soft_delete' do
    post 'Soft-delete a duplicate or abandoned account (admin or board)' do
      tags 'Members'
      description 'Hides the account from ordinary member lists and search, frees its email for reuse, removes the member from Slack and the ' \
                  'managed Google Drive folders, cancels any subscription, sets the status to inactive (revoked and suspended are kept) and ' \
                  'writes an audit entry. The member is never notified, and mail addressed to a soft-deleted member is dropped. Refused with 422 ' \
                  'when the member has an active unexpired membership or live subscription, or an open invoice (not settled and not refunded, which ' \
                  'includes a paid payment held for a fob). If a Slack or Drive removal fails, or was skipped for a member who has that access, it is ' \
                  'refused with 422 and manual_removal_required: true; remove them by hand and repeat with manual_removal_confirmed=true.'
      security [sessionAuth: []]
      produces 'application/json'
      parameter name: :id, in: :path, type: :string, description: 'Member id'
      parameter name: :manual_removal_confirmed, in: :query, type: :boolean, required: false,
                description: 'Set to true after removing the member from Slack and Drive by hand, to finish a delete that stopped with manual_removal_required.'

      response '200', 'The account was soft-deleted and the member is returned' do
        schema type: :object

        context 'an inactive duplicate account' do
          run_test! do
            expect(target.reload.merged_at).to be_present
            expect(target.status).to eq('inactive')
          end
        end

        context 'an active but expired account' do
          let(:target) { create(:member, status: 'activeMember', expirationTime: nil) }
          run_test! { expect(target.reload.status).to eq('inactive') }
        end

        context 'a revoked account keeps its status' do
          let(:target) { create(:member, status: 'revoked', expirationTime: nil) }
          run_test! { expect(target.reload.status).to eq('revoked') }
        end

        context 'with a Slack failure the admin has handled by hand' do
          let(:manual_removal_confirmed) { true }
          before do
            allow(Service::MemberAccess).to receive(:full_deprovision)
              .and_return(clean_removal.merge(slack: { status: :error, message: 'not_allowed_token_type' }))
          end
          run_test! { expect(target.reload.merged_at).to be_present }
        end
      end

      response '422', 'The delete was refused' do
        schema type: :object, required: %w[message], properties: {
          message: { type: :string },
          open_invoices: { type: :integer, description: 'Present when the refusal is because of open invoices.' },
          manual_removal_required: { type: :boolean, description: 'True when a Slack or Drive removal still has to be done by hand.' },
          problems: { type: :array, items: { type: :string }, description: 'What could not be removed automatically; present with manual_removal_required.' }
        }

        context 'an active, unexpired membership' do
          let(:target) { create(:member, status: 'activeMember', expirationTime: 1.month.from_now.to_i * 1000) }
          run_test! { |response| expect(JSON.parse(response.body)['message']).to match(/active, unexpired membership/); expect(target.reload.merged_at).to be_nil }
        end

        context 'an open invoice, including a paid payment held for a fob' do
          before { create(:invoice, member: target, transaction_id: 'held_txn') }
          run_test! do |response|
            expect(JSON.parse(response.body)).to include('open_invoices' => 1)
            expect(target.reload.merged_at).to be_nil
          end
        end

        context 'a Slack or Drive removal that failed' do
          before do
            allow(Service::MemberAccess).to receive(:full_deprovision)
              .and_return(clean_removal.merge(slack: { status: :error, message: 'not_allowed_token_type' }))
          end
          run_test! do |response|
            expect(JSON.parse(response.body)).to include('manual_removal_required' => true, 'problems' => ['Slack: not_allowed_token_type'])
            expect(target.reload.merged_at).to be_nil
          end
        end

        context 'an account that is already deleted' do
          before { target.update_attribute(:merged_at, Time.current) }
          run_test! { |response| expect(JSON.parse(response.body)['message']).to match(/already deleted/) }
        end
      end
    end
  end

  path '/admin/members/{id}/restore' do
    post 'Restore a soft-deleted account (admin or board)' do
      tags 'Members'
      description 'Makes the account appear in member lists and search again. It does not change the status (an account deleted through the portal stays ' \
                  'inactive until an admin reactivates it) and does not re-grant Slack or Drive access.'
      security [sessionAuth: []]
      produces 'application/json'
      parameter name: :id, in: :path, type: :string, description: 'Member id'

      response '200', 'The account was restored and the member is returned' do
        schema type: :object
        before { target.update_attribute(:merged_at, Time.current) }
        run_test! { expect(target.reload.merged_at).to be_nil }
      end

      response '422', 'The account is not deleted' do
        schema type: :object, required: %w[message], properties: { message: { type: :string } }
        run_test! { |response| expect(JSON.parse(response.body)['message']).to match(/not deleted/) }
      end
    end
  end
end
