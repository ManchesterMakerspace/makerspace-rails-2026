require 'rails_helper'

RSpec.describe HouseholdsController, type: :controller do
  set_devise_mapping

  let(:plan) { 'household-membership-one-month-recurring' }
  let(:address) { { address_street: '12 Main St', address_postal_code: '03101' } }
  let(:primary) { create(:member, address.merge(expirationTime: nil)) }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Service::AuditLogger).to receive(:log)
    allow(Service::SlackConnector).to receive(:enque_message)
    create(:invoice, member: primary, resource_id: primary.id.to_s, resource_class: 'member', plan_id: plan, settled_at: Time.now)
  end

  def body
    JSON.parse(response.body)
  end

  it 'requires a signed-in member' do
    get :show, format: :json

    expect(response).to have_http_status(401)
  end

  context 'as the primary' do
    before { sign_in primary }

    it 'shows the household state, with keys the portal reads' do
      get :show, format: :json

      expect(response).to have_http_status(200)
      expect(body).to include('role' => nil, 'household_plan' => true, 'can_invite' => true, 'plan_size' => 2)
    end

    it 'invites, then shows the open invitation and no more room' do
      expect { post :invite, params: { email: 'second@example.com' }, format: :json }.to have_enqueued_mail(MemberMailer, :household_invitation)

      expect(response).to have_http_status(201)
      expect(body['role']).to eq('primary')
      expect(body['can_invite']).to be(false)
      expect(body['household']['invitations'].first).to include('email' => 'second@example.com', 'status' => 'pending')
      expect(body['household']).to include('size' => 2, 'seats_used' => 2)
    end

    it 'explains a refusal in plain words' do
      post :invite, params: { email: 'not an email' }, format: :json

      expect(response).to have_http_status(422)
      expect(response.body).to match(/valid email/)
    end

    it 'revokes an invitation and frees the seat' do
      post :invite, params: { email: 'second@example.com' }, format: :json
      id = body['invitation_id']

      delete :revoke, params: { id: id }, format: :json

      expect(response).to have_http_status(200)
      expect(body['household']['invitations']).to eq([])
      expect(body['household']['seats_used']).to eq(1)
      expect(body['can_invite']).to be(true)
    end

    it 'resends an invitation' do
      post :invite, params: { email: 'second@example.com' }, format: :json
      id = body['invitation_id']

      expect { post :resend, params: { id: id }, format: :json }.to have_enqueued_mail(MemberMailer, :household_invitation)

      expect(response).to have_http_status(200)
      expect(HouseholdInvitation.find(id).sent_count).to eq(2)
    end

    it 'cannot touch another household\'s invitation' do
      other = create(:member, address)
      create(:invoice, member: other, resource_id: other.id.to_s, resource_class: 'member', plan_id: plan, settled_at: Time.now)
      invitation = HouseholdInvitations.invite!(primary: other, email: 'theirs@example.com')

      delete :revoke, params: { id: invitation.id.to_s }, format: :json

      expect(response).to have_http_status(403)
      expect(invitation.reload.status).to eq('pending')
    end

    it 'returns 404 for an invitation that does not exist' do
      delete :revoke, params: { id: BSON::ObjectId.new.to_s }, format: :json

      expect(response).to have_http_status(404)
    end
  end

  context 'as the invited person' do
    let(:invitation) { HouseholdInvitations.invite!(primary: primary, email: 'second@example.com') }
    let(:token) { invitation.issue_token! }
    let(:second) { create(:member, address.merge(email: 'second@example.com', expirationTime: nil)) }

    before { sign_in second }

    it 'previews the household address, then joins' do
      get :preview, params: { token: token }, format: :json
      expect(response).to have_http_status(200)
      expect(body).to include('household_address' => '12 Main St, 03101', 'address_matches' => true)

      post :accept, params: { token: token }, format: :json

      expect(response).to have_http_status(200)
      expect(body['role']).to eq('secondary')
      expect(second.reload.groupName).to eq(primary.id.to_s)
    end

    it 'cannot invite anyone' do
      post :invite, params: { email: 'x@example.com' }, format: :json

      expect(response).to have_http_status(422)
      expect(response.body).to match(/not on a household plan|Only the primary/)
    end

    it 'is refused with the invited address masked when signed in as someone else' do
      sign_in create(:member, address.merge(email: 'intruder@example.com'))

      post :accept, params: { token: token }, format: :json

      expect(response).to have_http_status(403)
      expect(response.body).to match(/s\*+@example.com/)
      expect(response.body).not_to include('second@example.com')
    end
  end
end

RSpec.describe HouseholdInvitationsController, type: :controller do
  let(:plan) { 'household-membership-one-month-recurring' }

  it 'shows only the inviter, the invited email and the expiry, without signing in' do
    ActiveJob::Base.queue_adapter = :test
    allow(Service::AuditLogger).to receive(:log)
    allow(Service::SlackConnector).to receive(:enque_message)
    primary = create(:member, address_street: '12 Main St', address_postal_code: '03101', firstname: 'Pat', lastname: 'Primary', expirationTime: nil)
    create(:invoice, member: primary, resource_id: primary.id.to_s, resource_class: 'member', plan_id: plan, settled_at: Time.now)
    token = HouseholdInvitations.invite!(primary: primary, email: 'second@example.com').issue_token!

    get :show, params: { token: token }, format: :json

    expect(response).to have_http_status(200)
    body = JSON.parse(response.body)
    expect(body.keys).to contain_exactly('status', 'inviter_name', 'invited_email', 'expires_at')
    expect(body).to include('inviter_name' => 'Pat P.', 'invited_email' => 'second@example.com', 'status' => 'pending')
    expect(response.body).not_to match(/Main St|03101/)
  end

  it 'returns 404 for an unknown link' do
    get :show, params: { token: 'nonsense' }, format: :json

    expect(response).to have_http_status(404)
  end
end
