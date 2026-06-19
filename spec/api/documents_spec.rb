require 'swagger_helper'

describe 'Documents API', type: :request do
  let(:customer) { create(:member, customer_id: "foo") }
  let(:non_customer) { create(:member) }

  path '/documents/{id}' do 
    get 'Get a document' do 
      tags 'Documents'
      operationId 'getDocument'
      parameter name: :id, in: :path, type: :string
      parameter name: :saved, in: :query, type: :boolean, required: false
      parameter name: :resource_id, in: :query, type: :string, required: false
      
      response '200', 'Document found' do 
        before do
          sign_in customer
        end
        let(:id) { "code_of_conduct" }
        run_test!
      end

      # This is an HTML request so they'll just be redirected to the login page if not auth'd
      response '302', 'User not authenticated' do
        let(:id) { "code_of_conduct" }
        run_test!
      end


      response '403', 'Saved rental agreement belongs to another member' do
        before do
          sign_in customer
        end

        let(:id) { "rental_agreement" }
        let(:saved) { true }
        let(:resource_id) { create(:rental).id.to_s }

        run_test!
      end

      response '200', 'Saved rental agreement belongs to current member' do
        before do
          sign_in customer
          file = Tempfile.new(["rental_agreement", ".pdf"])
          allow(::Service::GoogleDrive).to receive(:get_document).and_return(file)
        end

        let(:id) { "rental_agreement" }
        let(:saved) { true }
        let(:resource_id) { create(:rental, member: customer).id.to_s }

        run_test!
      end

      response '404', 'Document not found' do
        before { sign_in customer }
        schema '$ref' => '#/components/schemas/error'

        let(:id) { "invalid" }
        run_test!
      end
    end
  end
end