require 'rails_helper'

# A member saying they have vacated does not release a rental: it waits (awaiting_verification)
# until staff confirm the space is empty.
RSpec.describe RentalsController, type: :controller do
  set_devise_mapping

  let(:owner) { create(:member, :current) }
  let(:staff) { create(:member, :current, :resource_manager) }
  let(:rental) { create(:rental, member: owner, status: 'active') }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Service::SlackConnector).to receive(:enque_message)
    allow(Service::AuditLogger).to receive(:log)
  end

  def body
    JSON.parse(response.body)
  end

  describe 'DELETE #cancel with vacated=true' do
    before { sign_in owner }

    it 'holds the spot for verification instead of cancelling, and asks staff to check' do
      expect { delete :cancel, params: { id: rental.id.to_s, vacated: 'true' }, format: :json }
        .not_to have_enqueued_mail(RentalMailer, :rental_ended)

      expect(response).to have_http_status(200)
      expect(rental.reload.status).to eq('awaiting_verification')
      expect(rental.vacated_reported_at).to be_within(1.minute).of(Time.current)
      expect(Service::SlackConnector).to have_received(:enque_message)
        .with(a_string_including('Verify Vacated'), Service::SlackConnector.members_relations_channel, anything)
    end

    it 'removes the rental invoice, as vacating always did' do
      invoice = instance_double(Invoice, destroy: true)
      allow(Invoice).to receive(:active_invoice_for_resource).with(rental.id).and_return(invoice)

      delete :cancel, params: { id: rental.id.to_s, vacated: 'true' }, format: :json

      expect(invoice).to have_received(:destroy)
    end

    it 'still lets a member keep the rental until the end of the period (vacating)' do
      delete :cancel, params: { id: rental.id.to_s, vacated: 'false' }, format: :json

      expect(rental.reload.status).to eq('vacating')
    end
  end

  describe 'POST #mark_vacated' do
    let(:rental) { create(:rental, member: owner, status: 'vacating') }

    it 'a member marking their own rental holds it for verification' do
      sign_in owner

      post :mark_vacated, params: { id: rental.id.to_s }, format: :json

      expect(response).to have_http_status(200)
      expect(rental.reload.status).to eq('awaiting_verification')
      expect(Service::AuditLogger).to have_received(:log).with(hash_including(event_type: 'rental_vacated_reported'))
    end

    %i[resource_manager board_member admin].each do |role|
      it "a #{role} marking someone else's rental releases it, as the verification" do
        sign_in create(:member, :current, role)

        expect { post :mark_vacated, params: { id: rental.id.to_s }, format: :json }
          .to have_enqueued_mail(RentalMailer, :rental_ended)

        expect(response).to have_http_status(200)
        expect(rental.reload.status).to eq('cancelled')
        expect(Service::AuditLogger).to have_received(:log).with(hash_including(event_type: 'rental_vacated'))
      end
    end

    it 'staff marking their own rental is not a verification' do
      mine = create(:rental, member: staff, status: 'vacating')
      sign_in staff

      post :mark_vacated, params: { id: mine.id.to_s }, format: :json

      expect(mine.reload.status).to eq('awaiting_verification')
    end

    it 'refuses another member' do
      sign_in create(:member, :current)

      post :mark_vacated, params: { id: rental.id.to_s }, format: :json

      expect(response).to have_http_status(403)
      expect(rental.reload.status).to eq('vacating')
    end

    it 'only applies to a vacating rental' do
      sign_in owner
      rental.update!(status: 'active')

      post :mark_vacated, params: { id: rental.id.to_s }, format: :json

      expect(response).to have_http_status(422)
    end
  end

  describe 'POST #verify_vacated' do
    let(:rental) { create(:rental, member: owner, status: 'awaiting_verification', vacated_reported_at: 2.days.ago) }

    %i[resource_manager board_member admin].each do |role|
      it "a #{role} verifies, releasing the rental and telling the member" do
        sign_in create(:member, :current, role)

        expect { post :verify_vacated, params: { id: rental.id.to_s }, format: :json }
          .to have_enqueued_mail(RentalMailer, :rental_ended)

        expect(response).to have_http_status(200)
        expect(body['status']).to eq('cancelled')
        expect(rental.reload.status).to eq('cancelled')
        expect(Service::AuditLogger).to have_received(:log).with(hash_including(event_type: 'rental_vacated_verified'))
      end
    end

    it 'the member cannot verify their own rental' do
      sign_in owner

      post :verify_vacated, params: { id: rental.id.to_s }, format: :json

      expect(response).to have_http_status(403)
      expect(rental.reload.status).to eq('awaiting_verification')
    end

    it 'a staff member cannot verify their own rental' do
      mine = create(:rental, member: staff, status: 'awaiting_verification')
      sign_in staff

      post :verify_vacated, params: { id: mine.id.to_s }, format: :json

      expect(response).to have_http_status(403)
      expect(response.body).to match(/Another staff member/)
      expect(mine.reload.status).to eq('awaiting_verification')
    end

    it 'only applies to a rental awaiting verification' do
      sign_in staff
      rental.update!(status: 'vacating')

      post :verify_vacated, params: { id: rental.id.to_s }, format: :json

      expect(response).to have_http_status(422)
      expect(rental.reload.status).to eq('vacating')
    end
  end
end
