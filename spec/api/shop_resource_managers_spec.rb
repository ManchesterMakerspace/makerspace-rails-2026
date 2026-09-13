require 'swagger_helper'

RSpec.describe 'Shop Resource Manager assignments', type: :request do
  let(:member) { create(:member, :admin, :current) }
  let(:manager) { create(:member, :resource_manager, :current, resource_manager_shop_ids: []) }
  let(:shop) { create(:shop) }
  before do
    ActiveJob::Base.queue_adapter = :test
    sign_in member
    allow(REDIS).to receive(:set)
  end
  path '/admin/shops/resource_manager_options' do
    get 'List members with the Resource Manager role for shop assignment (admin/board only)' do
      tags 'Shops'
      security [sessionAuth: []]
      produces 'application/json'
      response '200', 'Resource Manager choices' do
        schema type: :array, items: { '$ref' => '#/components/schemas/FixPerson' }
        before { manager }
        run_test! { |r| expect(JSON.parse(r.body).map { |m| m['id'] }).to include(manager.id.to_s) }
      end
      response '403', 'Only admin or board may assign Resource Managers' do
        let(:member) { manager }
        run_test!
      end
    end
  end
  path '/shops' do
    get 'List visible shops including Resource Managers' do
      tags 'Shops'
      security [sessionAuth: []]
      produces 'application/json'
      response('200', 'Visible shops') do
        schema type: :array, items: { '$ref' => '#/components/schemas/Shop' }
        before { shop }
        run_test!
      end
    end
  end
  path '/admin/shops' do
    get 'List managed shops including current Resource Managers' do
      tags 'Shops'
      security [sessionAuth: []]
      produces 'application/json'
      response('200', 'Managed shops') do
        schema type: :array, items: { '$ref' => '#/components/schemas/Shop' }
        before { shop }
        run_test!
      end
    end
    post 'Create shop with optional Resource Manager assignments (admin/board)' do
      tags 'Shops'
      security [sessionAuth: []]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, schema: { '$ref' => '#/components/schemas/ShopWrite' }
      let(:body) { { name: 'New workshop', resource_manager_ids: [manager.id.to_s] } }
      response('200', 'Created shop') do
        schema '$ref' => '#/components/schemas/Shop'
        run_test! do |r|
          data = JSON.parse(r.body)
          expect(manager.reload.resource_manager_shop_ids).to include(data['id'])
          expect(data['resourceManagers'].map { |m| m['id'] }).to eq([manager.id.to_s])
        end
      end
    end
  end
  path '/admin/shops/{id}' do
    parameter name: :id, in: :path, type: :string
    %i[put patch].each do |verb|
      public_send(verb, 'Update shop; only admin/board may replace Resource Managers') do
        tags 'Shops'
        security [sessionAuth: []]
        consumes 'application/json'
        produces 'application/json'
        parameter name: :body, in: :body, schema: { '$ref' => '#/components/schemas/ShopWrite' }
        let(:id) { shop.id.to_s }
        let(:body) { { resource_manager_ids: [manager.id.to_s] } }
        response('200', 'Updated shop') do
          schema '$ref' => '#/components/schemas/Shop'
          let(:member) { create(:member, :board_member, :current) }
          run_test! do
            expect(manager.reload.resource_manager_shop_ids).to include(shop.id.to_s)
            expect(AuditLog.where(resource_id: shop.id, event_type: 'shop_resource_managers_changed')).to exist
          end
        end
        response('403', 'Resource Managers cannot change their own assignments') do
          let(:member) { manager }
          before { manager.update!(resource_manager_shop_ids: [shop.id.to_s]) }
          run_test!
        end
      end
    end
  end

  it 'removes only this shop, preserves other shops, and leaves assignments alone when omitted' do
    other = create(:shop)
    manager.update!(resource_manager_shop_ids: [shop.id.to_s, other.id.to_s])
    put "/api/admin/shops/#{shop.id}", params: { name: 'Renamed' }, as: :json
    expect(response).to have_http_status(:ok)
    expect(manager.reload.resource_manager_shop_ids).to include(shop.id.to_s)
    put "/api/admin/shops/#{shop.id}", params: { resource_manager_ids: [] }, as: :json
    expect(response).to have_http_status(:ok)
    expect(manager.reload.resource_manager_shop_ids).to eq([other.id.to_s])
  end
  it 'rejects non-RM selections before changing the shop' do
    put "/api/admin/shops/#{shop.id}", params: { name: 'Invalid edit', resource_manager_ids: [member.id.to_s] }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(shop.reload.name).not_to eq('Invalid edit')
  end
end
