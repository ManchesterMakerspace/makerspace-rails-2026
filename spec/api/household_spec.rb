require 'swagger_helper'

describe 'Household API', type: :request do
  let(:plan) { 'household-membership-one-month-recurring' }
  let(:address) { { address_street: '12 Main St', address_postal_code: '03101' } }
  let(:primary) { create(:member, address.merge(expirationTime: nil)) }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Service::AuditLogger).to receive(:log)
    allow(Service::SlackConnector).to receive(:enque_message)
    create(:invoice, member: primary, resource_id: primary.id.to_s, resource_class: 'member', plan_id: plan, settled_at: Time.now)
  end

  def invitation_for(email = 'second@example.com')
    HouseholdInvitations.invite!(primary: primary, email: email)
  end

  path '/household' do
    get "Shows the signed-in member's household: role, seats, open invitations, and whether they can invite" do
      tags 'Household'
      operationId 'getHousehold'
      produces 'application/json'
      security [sessionAuth: []]

      response '200', 'Household state' do
        before { sign_in primary }
        schema '$ref' => '#/components/schemas/Household'
        run_test! { |response| expect(JSON.parse(response.body)).to include('can_invite' => true, 'plan_size' => 2) }
      end

      response '401', 'Not signed in' do
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end
  end

  path '/household/invitations' do
    post 'The household primary invites a second adult by email (holds a seat for 14 days)' do
      tags 'Household'
      operationId 'inviteToHousehold'
      consumes 'application/json'
      produces 'application/json'
      security [sessionAuth: []]
      parameter name: :invitation, in: :body, schema: {
        type: :object, required: %w[email],
        properties: { email: { type: :string, description: 'Only this address can accept. An existing account must be signed in with it.' } }
      }
      let(:invitation) { { email: 'second@example.com' } }

      response '201', 'Invitation sent' do
        before { sign_in primary }
        schema '$ref' => '#/components/schemas/Household'
        run_test! { |response| expect(JSON.parse(response.body)['household']['invitations'].first).to include('email' => 'second@example.com') }
      end

      response '422', 'Not allowed: bad email, payment not accepted, household full, or the person cannot join yet' do
        before { sign_in primary }
        schema '$ref' => '#/components/schemas/error'
        let(:invitation) { { email: 'not an email' } }
        run_test!
      end

      response '429', 'Sent to this address too recently, or the daily limit for this sender or address was reached' do
        before do
          sign_in primary
          invitation_for('second@example.com')
        end
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end
  end

  path '/household/invitations/{id}/resend' do
    post 'Sends a new link (the old one stops working) and restarts the 14 days' do
      tags 'Household'
      operationId 'resendHouseholdInvitation'
      produces 'application/json'
      security [sessionAuth: []]
      parameter name: :id, in: :path, type: :string
      let(:id) { invitation_for.id.to_s }

      response '200', 'Resent' do
        before do
          sign_in primary
          id
          clear_household_invite_cooldown
        end
        schema '$ref' => '#/components/schemas/Household'
        run_test!
      end

      response '429', 'Sent again too soon, or the daily limit for this sender or address was reached' do
        before { sign_in primary }
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end

      response '403', "Not the household's primary" do
        before { sign_in create(:member) }
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end
  end

  path '/household/invitations/{id}' do
    delete 'Cancels an invitation: the link stops working and the seat is free again' do
      tags 'Household'
      operationId 'revokeHouseholdInvitation'
      produces 'application/json'
      security [sessionAuth: []]
      parameter name: :id, in: :path, type: :string
      let(:id) { invitation_for.id.to_s }

      response '200', 'Cancelled' do
        before { sign_in primary }
        schema '$ref' => '#/components/schemas/Household'
        run_test! { |response| expect(JSON.parse(response.body)['household']['seats_used']).to eq(1) }
      end

      response '404', 'No such invitation' do
        before { sign_in primary }
        schema '$ref' => '#/components/schemas/error'
        let(:id) { BSON::ObjectId.new.to_s }
        run_test!
      end
    end
  end

  path '/household/invitations/preview' do
    post 'The invited person, signed in, sees the household address they must match before joining (token in the body, so it is not logged)' do
      tags 'Household'
      operationId 'previewHouseholdInvitation'
      consumes 'application/json'
      produces 'application/json'
      security [sessionAuth: []]
      parameter name: :preview, in: :body, schema: { type: :object, required: %w[token], properties: { token: { type: :string } } }
      let(:second) { create(:member, address.merge(email: 'second@example.com', expirationTime: nil)) }
      let(:preview) { { token: invitation_for.issue_token! } }

      response '200', 'Preview' do
        before { sign_in second }
        schema '$ref' => '#/components/schemas/HouseholdInvitationPreview'
        run_test! { |response| expect(JSON.parse(response.body)).to include('address_matches' => true, 'household_address' => '12 Main St, 03101') }
      end

      response '403', 'Signed in with a different email than the invitation' do
        before { sign_in create(:member, address.merge(email: 'other@example.com')) }
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end
  end

  path '/household/invitations/accept' do
    post 'The invited person, signed in with the invited email, joins the household' do
      tags 'Household'
      operationId 'acceptHouseholdInvitation'
      consumes 'application/json'
      produces 'application/json'
      security [sessionAuth: []]
      parameter name: :accept, in: :body, schema: { type: :object, required: %w[token], properties: { token: { type: :string } } }
      let(:second) { create(:member, address.merge(email: 'second@example.com', expirationTime: nil)) }
      let(:accept) { { token: invitation_for.issue_token! } }

      response '200', 'Joined; the new household state' do
        before { sign_in second }
        schema '$ref' => '#/components/schemas/Household'
        run_test! { |response| expect(JSON.parse(response.body)['role']).to eq('secondary') }
      end

      response '422', 'Address mismatch, payment not accepted, existing membership, expired or used link' do
        before { sign_in create(:member, address.merge(email: 'second@example.com', address_street: '99 Other Rd', expirationTime: nil)) }
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end
  end

  path '/household_invitations/lookup' do
    post 'Public: who invited you and until when, from the emailed link (token in the body, so it is not logged)' do
      tags 'Household'
      operationId 'getHouseholdInvitation'
      consumes 'application/json'
      produces 'application/json'
      parameter name: :lookup, in: :body, schema: { type: :object, required: %w[token], properties: { token: { type: :string } } }
      let(:lookup) { { token: invitation_for.issue_token! } }

      response '200', 'Invitation summary (no household details; a cancelled, expired or used link shows only its status)' do
        schema '$ref' => '#/components/schemas/HouseholdInvitationPublic'
        run_test! { |response| expect(response.body).not_to match(/Main St|03101/) }
      end

      response '404', 'Unknown link' do
        schema '$ref' => '#/components/schemas/error'
        let(:lookup) { { token: 'nonsense' } }
        run_test!
      end
    end
  end
end
