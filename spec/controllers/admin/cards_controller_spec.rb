require 'rails_helper'

RSpec.describe Admin::CardsController, type: :controller do
  before { allow(CloudflareRails::Importer).to receive(:cloudflare_ips).and_return([]) }

  let(:member) { create(:member) }
  let(:other_member) { create(:member) }

  let(:valid_attributes) {
    {
      member_id: member.id,
      uid: '04A1B2C3'
    }
  }

  let(:duplicate_member_card) {
    {
      member_id: member.id,
      uid: '04A1B2C4'
    }
  }

  let(:second_member_card) {
    {
      member_id: member.id,
      uid: '04A1B2C5'
    }
  }

  let(:different_member_cards) {
    {
      member_id: other_member.id,
      uid: '04A1B2C6'
    }
  }

  describe "Authenticated admin" do
    login_admin
    describe "GET #index" do
      it "retrieves all cards of requested member" do
        card = Card.create! valid_attributes
        also_member_card = Card.create! duplicate_member_card
        diff_member_card = Card.create! different_member_cards

        get :index, params: { memberId: card.member.id.as_json }
        member_cards = Card.where(member_id: card.member.id).to_a
        expect(member_cards).to include(card, also_member_card)
        expect(member_cards).not_to include(diff_member_card)
      end
    end

    describe "GET #new" do
      it "retrieves the last rejection card not assigned to a member" do
        get :new, params: {}
        expect(response).to have_http_status(200)
      end
    end

    describe "POST #create" do
      context "with valid params" do
        it "creates a new Card if member doesn't have one" do
          expect {
            post :create, params: valid_attributes, format: :json
          }.to change(Card, :count).by(1)
        end

        it "renders json of the created card" do
            post :create, params: valid_attributes, format: :json

          parsed_response = JSON.parse(response.body)
          expect(response).to have_http_status(200)
          expect(response.media_type).to eq "application/json"
          expect(parsed_response['id']).to eq(Card.last.id.as_json)
        end

        it "invalidates existing cards if member already has one" do
          first_card = Card.create! valid_attributes
          second_card = Card.create! second_member_card
          expect {
            post :create, params: duplicate_member_card, format: :json
          }.to change(Card, :count)
          first_card.reload
          second_card.reload
          expect(first_card.validity).to eq("lost")
          expect(second_card.validity).to eq("lost")
        end

        it "duplicate cards for a members returns status 200" do
          card = Card.create! valid_attributes
          post :create, params: duplicate_member_card, format: :json
          card.reload

          parsed_response = JSON.parse(response.body)
          expect(response).to have_http_status(200)
          expect(response.media_type).to eq "application/json"
          expect(parsed_response['id']).to eq(Card.last.id.as_json)
          expect(Card.last.id.as_json).not_to eq(card.id)
        end
      end

      context "with invalid params" do
        let(:missing_uid_attributes) {
          {
            member_id: member.id
          }
        }
        let(:missing_member_attributes) {
          {
            uid: '04A1B2C7'
          }
        }
        it "does not create new card without uid" do
          expect {
            post :create, params: missing_uid_attributes, format: :json
          }.not_to change(Card, :count)
        end

        it "does not create new card without member" do
          expect {
            post :create, params: missing_member_attributes, format: :json
          }.not_to change(Card, :count)
        end

        it "invalid cards return status 422" do
          post :create, params: missing_uid_attributes, format: :json
          parsed_response = JSON.parse(response.body)
          expect(response).to have_http_status(422)
          expect(parsed_response['message']).to match(/uid/i)

          post :create, params: missing_member_attributes, format: :json
          expect(response).to have_http_status(422)
        end
      end
    end

    describe "PUT #update" do
      context "with valid params" do

        let(:valid_lost_attributes) {
          {
            member_id: member.id,
            uid: '04A1B2C3',
            card_location: 'lost'
          }
        }

        let(:valid_stolen_attributes) {
          {
            member_id: member.id,
            uid: '04A1B2C3',
            card_location: 'stolen'
          }
        }

        it "updates the requested card to lost" do
          card = Card.create! valid_attributes
          put :update, params: valid_lost_attributes.merge({id: card.to_param}), format: :json
          card.reload
          expect(card.validity).to eq('lost')
        end

        it "updates the requested card to stolen" do
          card = Card.create! valid_attributes
          put :update, params: valid_stolen_attributes.merge({id: card.to_param}), format: :json
          card.reload
          expect(card.validity).to eq('stolen')
        end

        it "renders json of the updated card" do
          card = Card.create! valid_attributes
          put :update, params: valid_stolen_attributes.merge({id: card.to_param}), format: :json
          parsed_response = JSON.parse(response.body)
          expect(response).to have_http_status(200)
          expect(response.media_type).to eq "application/json"
          expect(parsed_response['id']).to eq(Card.last.id.to_s)
        end
      end
    end

    describe "DELETE #destroy" do
      it "forgets a lost fob and records an audit event" do
        card = Card.create!(valid_attributes)
        card.set(validity: 'lost')

        expect { delete :destroy, params: { id: card.id }, format: :json }
          .to change(Card, :count).by(-1)

        entry = AuditLog.where(resource_id: card.id, event_type: 'lost_card_forgotten').last
        expect(response).to have_http_status(:no_content)
        expect(entry).to be_present
        expect(entry.actor_id).to be_present
      end

      it "unassigns a revoked member's fob and clears the legacy cardID" do
        card = Card.create!(valid_attributes)
        member.set(status: 'revoked', cardID: card.uid)

        expect { delete :destroy, params: { id: card.id }, format: :json }
          .to change(Card, :count).by(-1)

        expect(response).to have_http_status(:no_content)
        expect(member.reload.cardID).to be_nil
        expect(AuditLog.where(resource_id: card.id, event_type: 'card_unassigned')).to exist
      end

      it "does not remove an active fob" do
        card = Card.create!(valid_attributes)

        expect { delete :destroy, params: { id: card.id }, format: :json }
          .not_to change(Card, :count)

        expect(response).to have_http_status(422)
      end
    end
  end

  describe "Unauthorized" do
    describe "GET #index" do
      it "Returns 401" do
        card = Card.create! valid_attributes
        get :index, params: {id: card.member.id}, format: :json
        expect(response).to have_http_status(401)
      end
    end
    describe "GET #new" do
      it "Returns 401" do
        get :new, params: {}, format: :json
        expect(response).to have_http_status(401)
      end
    end
    describe "POST #create" do
      it "Returns 401" do
        post :create, params: {"card" => valid_attributes}, format: :json
        expect(response).to have_http_status(401)
      end
    end
    describe "PUT #update" do
      it "Returns 401" do
        card = Card.create! valid_attributes
        put :update, params: {id: card.to_param, card: valid_attributes}, format: :json
        expect(response).to have_http_status(401)
      end
    end
  end

  describe "Basic User" do
    login_user
    describe "GET #index" do
      it "Returns 401" do
        card = Card.create! valid_attributes
        get :index, params: {id: card.member.id}, format: :json
        expect(response).to have_http_status(403)
      end
    end
    describe "GET #new" do
      it "Returns 401" do
        get :new, params: {}, format: :json
        expect(response).to have_http_status(403)
      end
    end
    describe "POST #create" do
      it "Returns 401" do
        post :create, params: {"card" => valid_attributes}, format: :json
        expect(response).to have_http_status(403)
      end
    end
    describe "PUT #update" do
      it "Returns 401" do
        card = Card.create! valid_attributes
        put :update, params: {id: card.to_param, card: valid_attributes}, format: :json
        expect(response).to have_http_status(403)
      end
    end
  end
end
