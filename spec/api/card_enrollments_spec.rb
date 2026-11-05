require 'swagger_helper'

describe 'Native card enrollment', type: :request do
  let(:operator) { create(:member, :admin, expirationTime: 1.day.from_now.to_i * 1000) }
  before do
    sign_in operator
    allow(REDIS).to receive(:set).and_return(true)
    allow(Service::AuditLogger).to receive(:attempt_slack).and_return(true)
  end
  around do |example|
    old = ENV['READER_KEY_ENCRYPTION_KEY']
    ENV['READER_KEY_ENCRYPTION_KEY'] = Base64.strict_encode64('x' * 32)
    example.run
  ensure
    ENV['READER_KEY_ENCRYPTION_KEY'] = old
  end
  let(:recipient) { create(:member, :current, member_contract_signed_date: Date.today) }
  %w[admin fob_issuance].each do |scope|
    context "#{scope} workflow" do
    let(:workflow) { scope == 'admin' ? 'admin' : 'issuer' }
    let(:prepared) { CardEnrollment.new(operator, workflow).prepare!(recipient.id, '01020304', true) }
    before do
      if scope == 'fob_issuance'
        tool = create(:tool, grants_fob_issuance: true)
        create(:tool_checkout, member: operator, tool: tool)
      end
    end
    path "/#{scope}/card_enrollments" do
      post 'Prepare or resume protected card enrollment' do
        tags 'Cards'
        security [sessionAuth: []]
        consumes 'application/json'
        produces 'application/json'
        parameter name: :body, in: :body, required: true, schema: {
          type: :object, required: %w[memberId uid idVerified], properties: {
            memberId: { type: :string }, uid: { type: :string, pattern: '^(?:[0-9A-F]{8}|[0-9A-F]{14})$' }, idVerified: { type: :boolean }
          }
        }
        let(:body) { { memberId: operator.id.to_s, uid: '01020304', idVerified: true } }
        response '200', 'Durable pending material or completed retry', requires_transactions: true do
          let(:body) { { memberId: recipient.id.to_s, uid: '01020304', idVerified: true } }
          schema type: :object, required: %w[id uid memberId cardId revision state], properties: {
            id: { type: :string }, uid: { type: :string }, memberId: { type: :string }, cardId: { type: :string },
            revision: { type: :integer }, state: { type: :string, enum: %w[pending completed] },
            material: { type: :object, required: %w[keyA keyB contents digest version], properties: {
              keyA: { type: :string }, keyB: { type: :string }, contents: { type: :string }, digest: { type: :string }, version: { type: :integer }
            } }
          }
          run_test! { |response| expect(JSON.parse(response.body)['state']).to eq('pending') }
        end
        response '422', 'Invalid identity attestation' do
          let(:body) { { memberId: recipient.id.to_s, uid: '01020304', idVerified: false } }
          run_test!
        end
        response '409', 'Conflicting assignment', requires_transactions: true do
          let(:body) { { memberId: recipient.id.to_s, uid: '01020304', idVerified: true } }
          before { create(:card, member: operator, uid: '01020304') }
          run_test!
        end
        response '503', 'Enrollment storage or encryption unavailable' do
          before { allow_any_instance_of(CardEnrollment).to receive(:prepare!).and_raise(CardManagement::Unavailable, 'Unavailable') }
          run_test!
        end
        response '403', 'Operator lacks this workflow authority' do
          before { operator.update!(role: 'member', expirationTime: 1.day.ago.to_i * 1000) }
          run_test!
        end
        response '401', 'Authentication required' do
          before { sign_out operator }
          run_test!
        end
      end
    end
    path "/#{scope}/card_enrollments/{id}" do
      get 'Read secret-free enrollment status' do
        tags 'Cards'
        security [sessionAuth: []]
        produces 'application/json'
        parameter name: :id, in: :path, required: true, schema: { type: :string }
        let(:id) { 'unknown' }
        response '200', 'Enrollment status without keys', requires_transactions: true do
          let(:id) { prepared[:id] }
          run_test! { |response| expect(JSON.parse(response.body)).not_to have_key('material') }
        end

        response '403', 'Operator lacks this workflow authority' do
          before { operator.update!(role: 'member', expirationTime: 1.day.ago.to_i * 1000) }
          run_test!
        end
      end
    end
    path "/#{scope}/card_enrollments/{id}/commit" do
      post 'Commit verified enrollment and assignment atomically' do
        tags 'Cards'
        security [sessionAuth: []]
        consumes 'application/json'
        produces 'application/json'
        parameter name: :id, in: :path, required: true, schema: { type: :string }
        parameter name: :body, in: :body, required: true, schema: {
          type: :object, required: %w[revision digest], properties: { revision: { type: :integer }, digest: { type: :string } }
        }
        let(:id) { 'unknown' }
        let(:body) { { revision: 1, digest: '0' * 64 } }
        response '200', 'Verified assignment completed; exact retries are idempotent', requires_transactions: true do
          let(:id) { prepared[:id] }
          let(:body) { { revision: prepared[:revision], digest: prepared[:material]['digest'] } }
          run_test! { |response| expect(JSON.parse(response.body)['state']).to eq('completed') }
        end
        response '403', 'Operator lacks this workflow authority' do
          before { operator.update!(role: 'member', expirationTime: 1.day.ago.to_i * 1000) }
          run_test!
        end
      end
    end
  end
end
end
