require 'swagger_helper'

describe 'Rentals API', type: :request do
  path '/rentals' do 
    get 'Gets a list of rentals' do 
      tags 'Rentals'
      operationId "listRentals"
      consumes 'application/json'
      parameter name: :pageNum, in: :query, type: :number, required: false
      parameter name: :orderBy, in: :query, type: :string, required: false
      parameter name: :order, in: :query, type: :string, required: false

      response '200', 'rentals found' do 
        before { sign_in create(:member) }

        schema type: :array,
            items: { '$ref' => '#/components/schemas/Rental' }

        let(:rentals) { create_list(:rental) }
        run_test!
      end
    end
  end

  path '/rentals/{id}' do
    get 'Gets a rental' do 
      tags 'Rentals'
      operationId "getRental"
      consumes 'application/json'
      parameter name: :id, in: :path, type: :string

      response '200', 'rental found' do
        let(:current_member) { create(:member) }
        before { sign_in current_member }
        let(:id) { create(:rental, member: current_member).id }

        schema '$ref' => '#/components/schemas/Rental'

        run_test!
      end

      response '403', "Forbidden reading a different member's rental (owner and staff only)" do
        before { sign_in create(:member) }
        schema '$ref' => '#/components/schemas/error'
        let(:id) { create(:rental, member: create(:member)).id }
        run_test!
      end

      response '404', 'rental not found' do
        before { sign_in create(:member) }
        schema '$ref' => '#/components/schemas/error'
        let(:id) { 'invalid' }
        run_test!
      end

      response '401', 'User not authenciated' do 
        schema '$ref' => '#/components/schemas/error'
        let(:id) { create(:rental).id }
        run_test!
      end
    end

    put 'Updates a rental and uploads signature' do
      tags 'Rentals'
      operationId "updateRental"
      consumes 'application/json'
      parameter name: :id, in: :path, type: :string
      parameter name: :updateRentalDetails, in: :body, schema: {
        title: :updateRentalDetails,
        type: :object,
        properties: {
          signature: { type: :string }
        },
        required: [:signature]
      }, required: true

      # Update object
      let(:updateRentalDetails) {{ signature: "foobar" }}

      response '200', 'rental updated' do
        let(:current_member) { create(:member) }
        let(:rental) { create(:rental, member: current_member, status: "pending_agreement") }
        before { sign_in current_member }

        schema '$ref' => '#/components/schemas/Rental'

        let(:id) { rental.id }
        run_test!
      end

      response '403', "Forbidden updating different member's rental" do
        let(:current_member) { create(:member) }
        let(:other_user) { create(:member) }
        let(:rental) { create(:rental, member: other_user) }
        before { sign_in current_member }

        schema '$ref' => '#/components/schemas/error'

        let(:id) { rental.id }
        run_test!
      end

      response '401', 'User not authenciated or authorized' do
        schema '$ref' => '#/components/schemas/error'
        let(:id) { create(:rental).id }
        run_test!
      end

      response '404', 'Rental not found' do
        before { sign_in create(:member) }
        schema '$ref' => '#/components/schemas/error'

        let(:id) { 'invalid' }
        run_test!
      end
    end
  end

  # Ending a rental. A member saying they have vacated does not release the spot: the rental waits
  # (awaiting_verification) until staff verify the space is empty.
  context 'ending a rental' do
    let(:owner) { create(:member, :current) }
    let(:staff) { create(:member, :current, :resource_manager) }
    let(:signed_in) { owner }

    before do
      ActiveJob::Base.queue_adapter = :test
      allow(Service::SlackConnector).to receive(:enque_message)
      allow(Service::AuditLogger).to receive(:log)
      sign_in signed_in
    end

    path '/rentals/{id}/cancel' do
      delete "Cancels the signed-in member's rental; vacated=true holds it for staff verification" do
        tags 'Rentals'
        operationId 'cancelRental'
        produces 'application/json'
        parameter name: :id, in: :path, type: :string
        parameter name: :vacated, in: :query, type: :boolean, required: false,
                  description: 'true: the member says they have already vacated, so the rental becomes awaiting_verification. Otherwise it becomes vacating until its end date.'

        let(:id) { create(:rental, member: owner, status: 'active').id.to_s }

        response '200', 'Rental vacating, or awaiting verification when vacated=true' do
          schema '$ref' => '#/components/schemas/Rental'
          let(:vacated) { true }
          run_test! { |response| expect(JSON.parse(response.body)['status']).to eq('awaiting_verification') }

          context 'without vacated' do
            let(:vacated) { false }
            run_test! { |response| expect(JSON.parse(response.body)['status']).to eq('vacating') }
          end
        end

        response '403', "Not the signed-in member's rental" do
          schema '$ref' => '#/components/schemas/error'
          let(:vacated) { true }
          let(:id) { create(:rental, member: create(:member), status: 'active').id.to_s }
          run_test!
        end
      end
    end

    path '/rentals/{id}/mark_vacated' do
      post "Marks a vacating rental as vacated; staff on another member's rental release it, a member's own click waits for verification" do
        tags 'Rentals'
        operationId 'markRentalVacated'
        produces 'application/json'
        parameter name: :id, in: :path, type: :string

        let(:id) { create(:rental, member: owner, status: 'vacating').id.to_s }

        response '200', "Rental awaiting verification (member) or cancelled (staff on another member's rental)" do
          schema '$ref' => '#/components/schemas/Rental'
          run_test! { |response| expect(JSON.parse(response.body)['status']).to eq('awaiting_verification') }
        end

        response '403', "Neither the rental's member nor staff" do
          schema '$ref' => '#/components/schemas/error'
          let(:signed_in) { create(:member, :current) }
          let(:id) { create(:rental, member: owner, status: 'vacating').id.to_s }
          run_test!
        end

        response '422', 'Rental is not vacating' do
          schema '$ref' => '#/components/schemas/error'
          let(:id) { create(:rental, member: owner, status: 'active').id.to_s }
          run_test!
        end
      end
    end

    path '/rentals/{id}/verify_vacated' do
      post 'Staff (resource manager, board or admin) verify the space is empty and release a rental awaiting verification' do
        tags 'Rentals'
        operationId 'verifyRentalVacated'
        produces 'application/json'
        parameter name: :id, in: :path, type: :string

        let(:signed_in) { staff }
        let(:id) { create(:rental, member: owner, status: 'awaiting_verification').id.to_s }

        response '200', 'Rental cancelled and the member told it has ended' do
          schema '$ref' => '#/components/schemas/Rental'
          run_test! { |response| expect(JSON.parse(response.body)['status']).to eq('cancelled') }
        end

        response '403', 'Not staff, or staff verifying their own rental' do
          schema '$ref' => '#/components/schemas/error'
          let(:signed_in) { owner }
          run_test!
        end

        response '422', 'Rental is not awaiting verification' do
          schema '$ref' => '#/components/schemas/error'
          let(:id) { create(:rental, member: owner, status: 'vacating').id.to_s }
          run_test!
        end
      end
    end
  end
end
