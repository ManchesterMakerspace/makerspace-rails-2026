require 'rails_helper'

RSpec.describe 'Admin tools', type: :request do
  let(:shop) { Shop.create!(name: 'Woodshop', slack_channel: 'woodshop') }
  let(:admin) { create(:member, :admin) }

  it 'allows admins to create and update announce settings' do
    sign_in admin

    post '/api/admin/tools', params: { name: 'Table Saw', shop_id: shop.id.to_s, announce: true, announce_channel: 'tool-requests' }
    expect(response).to have_http_status(:ok)
    tool = Tool.last
    expect(tool.announce).to eq(true)
    expect(tool.announce_channel).to eq('tool-requests')

    put "/api/admin/tools/#{tool.id}", params: { announce: false, announce_channel: '' }
    expect(response).to have_http_status(:ok)
    expect(tool.reload.announce).to eq(false)
    expect(tool.announce_channel).to eq('')
  end
end
