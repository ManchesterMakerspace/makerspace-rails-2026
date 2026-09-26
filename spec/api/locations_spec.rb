require 'swagger_helper'

RSpec.describe 'Location contracts', type: :request do
  let(:member) { create(:member, :admin, :current) }
  let(:shop) { create(:shop) }
  let(:other_shop) { create(:shop) }
  let(:location) { create(:location, shop: shop, name: 'Cabinet 1') }
  before { sign_in member; allow(REDIS).to receive(:set).and_return(true) }

  path '/admin/locations' do
    get 'List locations, optionally scoped to a shop or a set of shops' do
      tags 'Locations'
      security [sessionAuth: []]
      produces 'application/json'
      parameter name: :shop_id, in: :query, type: :string, required: false
      parameter name: :shop_ids, in: :query, type: :array, items: { type: :string }, required: false
      response('200', 'Locations') do
        schema type: :array, items: { '$ref' => '#/components/schemas/Location' }
        let(:shop_id) { shop.id.to_s }
        before { location }
        run_test! { |r| expect(JSON.parse(r.body).map { |l| l['id'] }).to eq([location.id.to_s]) }
      end
    end
    post 'Create a location (admin/board or shop manager)' do
      tags 'Locations'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: { '$ref' => '#/components/schemas/LocationWrite' }
      let(:body) { { name: 'Cabinet 2', shop_id: shop.id.to_s, kind: 'cabinet' } }
      response('200', 'Created location') { schema '$ref' => '#/components/schemas/Location'; run_test! }
      response('403', 'Not a manager of this shop') do
        let(:member) { create(:member, :current) }
        run_test!
      end
      response('200', 'Created location with a drawn shape') do
        schema '$ref' => '#/components/schemas/Location'
        let(:body) do
          { name: 'Woodshop', shop_id: shop.id.to_s, kind: 'area',
            shape_points: [{ x: 10, y: 10 }, { x: 50, y: 10 }, { x: 30, y: 40 }] }
        end
        run_test! { |r| expect(JSON.parse(r.body)['shapePoints'].size).to eq(3) }
      end
      response('422', 'A shape needs at least 3 points') do
        let(:body) do
          { name: 'Woodshop', shop_id: shop.id.to_s, shape_points: [{ x: 10, y: 10 }, { x: 50, y: 10 }] }
        end
        run_test!
      end
    end
  end

  path '/admin/locations/{id}' do
    parameter name: :id, in: :path, type: :string
    let(:id) { location.id.to_s }

    %i[put patch].each do |verb|
      public_send(verb, 'Update a location (admin/board or shop manager)') do
        tags 'Locations'
        security [sessionAuth: []]
        consumes 'application/json'
        produces 'application/json'
        parameter name: :body, in: :body, schema: { '$ref' => '#/components/schemas/LocationWrite' }
        let(:body) { { name: 'Renamed cabinet', shop_id: shop.id.to_s } }
        response('200', 'Updated location') { schema '$ref' => '#/components/schemas/Location'; run_test! }
        response('200', 'Reassigned to a different shop (fixing a misplaced location)') do
          schema '$ref' => '#/components/schemas/Location'
          let(:body) { { name: location.name, shop_id: other_shop.id.to_s } }
          run_test! { |r| expect(JSON.parse(r.body)['shopId']).to eq(other_shop.id.to_s) }
        end
        response('422', 'Re-parenting to a descendant is rejected') do
          let(:child) { create(:location, shop: shop, name: 'Shelf 1', parent_id: location.id) }
          let(:body) { { name: location.name, shop_id: shop.id.to_s, parent_id: child.id.to_s } }
          before { child }
          run_test!
        end
      end
    end

    delete 'Delete a location (admin/board or shop manager)' do
      tags 'Locations'
      security [sessionAuth: []]
      response('204', 'Deleted') { run_test! }
    end
  end

  # Plain request spec, not an rswag contract example -- rswag's query-string
  # builder doesn't reliably round-trip an array `let` value for an
  # `in: :query, type: :array` parameter (confirmed: the request it built
  # didn't parse server-side as an array at all). The endpoint and its
  # shop_ids param are already documented via the `parameter` declaration
  # above; this just exercises the actual behavior directly.
  describe 'GET /api/admin/locations?shop_ids[]=...' do
    it 'returns locations across every requested shop' do
      location
      other_location = create(:location, shop: other_shop, name: 'Cabinet 2')

      get '/api/admin/locations', params: { shop_ids: [shop.id.to_s, other_shop.id.to_s] }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).map { |l| l['id'] }).to contain_exactly(location.id.to_s, other_location.id.to_s)
    end
  end
end
