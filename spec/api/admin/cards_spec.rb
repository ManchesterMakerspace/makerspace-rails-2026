require 'swagger_helper'

describe 'Admin::AccessCards API', type: :request do
  let(:admin) { create(:member, :admin) }
  let(:basic) { create(:member) }
  before { allow(CloudflareRails::Importer).to receive(:cloudflare_ips).and_return([]) }

  path '/admin/cards/by_uid' do
    get 'Gets an access card by its NFC UID' do
      tags 'Cards'
      operationId 'adminGetCardByUid'
      description 'Requires an authenticated member with the admin or board_member role.'
      security [cookieAuth: []]
      produces 'application/json'
      parameter name: :uid, in: :query, type: :string, required: true

      response '200', 'card found' do
        before { sign_in admin }
        schema '$ref' => '#/components/schemas/Card'
        let!(:card) do
          create(:card, member: basic, uid: '04A1B2C3').tap { |record| record.set(uid: '04:a1-b2 c3') }
        end
        let(:uid) { '04A1B2C3' }
        run_test! do |response|
          expect(JSON.parse(response.body)['memberId']).to eq(basic.id.to_s)
        end
      end

      response '404', 'card not found' do
        before { sign_in admin }
        schema '$ref' => '#/components/schemas/error'
        let(:uid) { 'DEADBEEF' }
        run_test!
      end

      response '403', 'user unauthorized' do
        before { sign_in basic }
        schema '$ref' => '#/components/schemas/error'
        let(:uid) { '04A1B2C3' }
        run_test!
      end

      response '401', 'user unauthenticated' do
        schema '$ref' => '#/components/schemas/error'
        let(:uid) { '04A1B2C3' }
        run_test!
      end
    end
  end

  path '/admin/cards/new' do 
    get 'Initiate new card creation' do 
      tags 'Cards'
      operationId "adminGetNewCard"
      consumes 'application/json'
      response '200', 'Card intilized' do 
        before do 
          sign_in admin 
          create(:rejection_card, timeOf: Time.now)
        end

        schema '$ref' => '#/components/schemas/RejectionCard'

        run_test!
      end

      response '403', 'User unauthorized' do 
        before { sign_in basic }
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end

      response '401', 'User unauthenticated' do 
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end
  end

  path '/admin/cards' do 
    get 'Gets a list of members cards' do 
      tags 'Cards'
      operationId "adminListCards"
      consumes 'application/json'
      parameter name: :memberId, in: :query, type: :string, required: true

      response '200', 'cards found' do 
        before { sign_in admin }
        schema type: :array,
            items: { '$ref' => '#/components/schemas/Card' }

        let(:memberId) { basic.id }

        run_test!
      end

      response '403', 'User unauthorized' do 
        before { sign_in basic }
        schema '$ref' => '#/components/schemas/error'
        let(:memberId) { basic.id }
        run_test!
      end

      response '401', 'User unauthenticated' do 
        schema '$ref' => '#/components/schemas/error'
        let(:memberId) { basic.id }
        run_test!
      end

      response '404', 'member not found' do 
        before { sign_in admin }
        schema '$ref' => '#/components/schemas/error'
        let(:memberId) { 'invalid' }
        run_test!
      end
    end

    post 'Creates an access card' do 
      tags 'Cards'
      operationId "adminCreateCard"
      consumes 'application/json'
      parameter name: :createAccessCardDetails, in: :body, schema: {
        title: :createAccessCardDetails,
        type: :object,
        properties: {
          memberId: { type: :string },
          uid: { type: :string },
        },
        required: [:memberId, :uid]
      }, required: true

      response '200', 'access card created' do 
        before { sign_in admin }

        schema '$ref' => '#/components/schemas/Card'

        let(:createAccessCardDetails) {{
          memberId: basic.id,
          uid: "04A1B2C3"
        }}

        run_test!
      end

      response '403', 'User unauthorized' do 
        before { sign_in basic }
        schema '$ref' => '#/components/schemas/error'
        let(:createAccessCardDetails) {{
          memberId: basic.id,
          uid: "04A1B2C3"
        }}
        run_test!
      end

      response '401', 'User unauthenticated' do 
        schema '$ref' => '#/components/schemas/error'
        let(:createAccessCardDetails) {{
          memberId: basic.id,
          uid: "04A1B2C3"
        }}
        run_test!
      end

      response '422', 'missing parameter' do 
        before { sign_in admin }
        schema '$ref' => '#/components/schemas/error'
        let(:createAccessCardDetails) {{
          uid: "04A1B2C3"
        }}
        run_test!
      end

      response '404', 'member not found' do 
        before { sign_in admin }
        schema '$ref' => '#/components/schemas/error'
        let(:createAccessCardDetails) {{
          memberId: 'invalid',
          uid: "04A1B2C3"
        }}
        run_test!
      end
    end
  end

  path "/admin/cards/{id}" do 
    put 'Updates a card' do 
      tags 'Cards'
      operationId "adminUpdateCard"
      consumes 'application/json'
      parameter name: :id, in: :path, type: :string

      parameter name: :updateAccessCardDetails, in: :body, schema: {
        title: :updateAccessCardDetails,
        type: :object,
        properties: {
          cardLocation: { type: :string }
        },
        required: [:cardLocation]
      }, required: true

      response '200', 'card updated' do 
        before { sign_in admin }

        schema '$ref' => '#/components/schemas/Card'

        let(:updateAccessCardDetails) {{
          cardLocation: "lost"
        }}
        let(:id) { create(:card, member: basic).id }
        run_test!
      end

      response '403', 'User unauthorized' do 
        before { sign_in basic }
        schema '$ref' => '#/components/schemas/error'
        let(:updateAccessCardDetails) {{
          cardLocation: "lost"
        }}
        let(:id) { create(:card).id }
        run_test!
      end

      response '401', 'User unauthenticated' do 
        schema '$ref' => '#/components/schemas/error'
        let(:updateAccessCardDetails) {{
          cardLocation: "lost"
        }}
        let(:id) { create(:card).id }
        run_test!
      end

      response '404', 'Invoice not found' do 
        before { sign_in admin }
        schema '$ref' => '#/components/schemas/error'
        let(:updateAccessCardDetails) {{
          cardLocation: "lost"
        }}
        let(:id) { 'card' }
        run_test!
      end
    end

    delete 'Removes a lost fob or unassigns a fob from an expired/revoked member' do
      tags 'Cards'
      operationId 'adminRemoveCard'
      description 'Requires an authenticated member with the admin or board_member role. Removal is limited to lost fobs and fobs assigned to expired or revoked members.'
      security [cookieAuth: []]
      parameter name: :id, in: :path, type: :string, required: true
      parameter name: :'X-XSRF-TOKEN', in: :header, type: :string, required: true,
                description: 'Decoded value of the XSRF-TOKEN cookie obtained from a safe request such as GET /config.'
      let(:'X-XSRF-TOKEN') { 'documented-csrf-token' }

      response '204', 'fob removed' do
        before { sign_in admin }
        let!(:card) { create(:card, member: basic, uid: '04A1B2C3') }
        let(:id) do
          card.set(validity: 'lost')
          card.id
        end
        run_test!
      end

      response '422', 'active fob cannot be removed' do
        before { sign_in admin }
        let!(:card) { create(:card, member: basic, uid: '04A1B2C3') }
        let(:id) { card.id }
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end

      response '403', 'user unauthorized' do
        before { sign_in basic }
        let(:id) { create(:card, uid: '04A1B2C3').id }
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end

      response '401', 'user unauthenticated' do
        let(:id) { create(:card, uid: '04A1B2C3').id }
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end

      response '404', 'card not found' do
        before { sign_in admin }
        let(:id) { '000000000000000000000000' }
        schema '$ref' => '#/components/schemas/error'
        run_test!
      end
    end
  end
end
