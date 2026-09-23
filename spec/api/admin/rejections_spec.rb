require 'swagger_helper'

describe 'Admin::Rejections API', type: :request do
  let(:admin) { create(:member, :admin) }
  let(:basic) { create(:member) }
  before { allow(CloudflareRails::Importer).to receive(:cloudflare_ips).and_return([]) }

  path '/admin/rejections' do
    post 'Records an unknown scanned card UID as a rejection' do
      tags 'Cards'
      operationId 'adminCreateRejection'
      description 'Requires an authenticated member with the admin or board_member role.'
      security [cookieAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :rejectionDetails, in: :body, required: true, schema: {
        type: :object,
        properties: { uid: { type: :string } },
        required: [:uid]
      }

      response '201', 'rejection recorded' do
        before { sign_in admin }
        schema '$ref' => '#/components/schemas/RejectionCard'
        let(:rejectionDetails) { { uid: '04:a1-b2 c3' } }
        run_test! do
          expect(RejectionCard.where(uid: '04A1B2C3').count).to eq(1)
        end
      end

      response '403', 'user unauthorized' do
        before { sign_in basic }
        schema '$ref' => '#/components/schemas/error'
        let(:rejectionDetails) { { uid: '04A1B2C3' } }
        run_test!
      end

      response '401', 'user unauthenticated' do
        schema '$ref' => '#/components/schemas/error'
        let(:rejectionDetails) { { uid: '04A1B2C3' } }
        run_test!
      end

      response '422', 'UID is blank or already belongs to a card' do
        before { sign_in admin }
        schema '$ref' => '#/components/schemas/error'
        let(:rejectionDetails) { { uid: ' ' } }
        run_test!
      end
    end
  end
end
