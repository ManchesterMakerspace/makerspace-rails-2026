require 'rails_helper'

RSpec.describe 'Admin rejections', type: :request do
  before { allow(CloudflareRails::Importer).to receive(:cloudflare_ips).and_return([]) }

  let(:member)       { create(:member) }
  let(:other_member) { create(:member) }
  let!(:member_card) { create(:card, member: member, uid: '04A1B2C3') }
  let!(:other_card)  { create(:card, member: other_member, uid: '04A1B2C4') }
  let!(:member_rejection) { create(:rejection_card, uid: member_card.uid) }
  let!(:other_rejection)  { create(:rejection_card, uid: other_card.uid) }

  def request_rejections(uids, time_range: {})
    get '/api/admin/rejections', params: { uids: uids.to_json }.merge(time_range)
  end

  describe 'POST /api/admin/rejections' do
    it 'allows a board member to record an unknown scanned UID' do
      sign_in create(:member, :board_member)

      post '/api/admin/rejections', params: { uid: '76:14-d5 a1' }, as: :json

      expect(response).to have_http_status(:created)
      expect(RejectionCard.where(uid: '7614D5A1', validity: 'rejected')).to exist
    end

    it 'does not record a UID that already belongs to a card' do
      sign_in create(:member, :admin)
      member_card.set(uid: '04:a1-b2 c3')

      post '/api/admin/rejections', params: { uid: '04A1B2C3' }, as: :json

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  context 'as a regular member' do
    before { sign_in member }

    it 'ignores requested cards not held by the member and redacts returned UIDs' do
      request_rejections([other_card.uid])

      expect(response).to have_http_status(:ok)
      rejections = JSON.parse(response.body).fetch('rejections')
      expect(rejections).to be_empty
    end

    it 'redacts the UID to a stable, non-raw value' do
      request_rejections([member_card.uid])
      rejection_uid = JSON.parse(response.body).fetch('rejections').first.fetch('uid')

      expect(rejection_uid).not_to eq(member_card.uid)

      request_rejections([member_card.uid])
      second_rejection_uid = JSON.parse(response.body).fetch('rejections').first.fetch('uid')

      expect(rejection_uid).to eq(second_rejection_uid)
    end

    it 'redacts to the same value as the checkins endpoint for the same raw UID' do
      checkins_collection = Mongoid.default_client[:checkins]
      checkins_collection.insert_one({ uid: member_card.uid, time: Time.now.to_i * 1000, timeOf: Time.now })

      get '/api/admin/checkins', params: { uids: [member_card.uid].to_json }
      checkin_uid = JSON.parse(response.body).fetch('checkins').first.fetch('uid')
      checkins_collection.delete_many({})

      request_rejections([member_card.uid])
      rejection_uid = JSON.parse(response.body).fetch('rejections').first.fetch('uid')

      expect(checkin_uid).to eq(rejection_uid)
    end
  end

  shared_examples 'privileged rejection access' do |role|
    let(:actor) { create(:member, :"#{role}") }

    before { sign_in actor }

    it "allows #{role} members to query the requested UID range and returns raw UIDs" do
      request_rejections([member_card.uid, other_card.uid])

      expect(response).to have_http_status(:ok)
      uids = JSON.parse(response.body).fetch('rejections').map { |rejection| rejection.fetch('uid') }
      expect(uids).to contain_exactly(member_card.uid, other_card.uid)
    end
  end

  include_examples 'privileged rejection access', :resource_manager
  include_examples 'privileged rejection access', :admin
  include_examples 'privileged rejection access', :board_member

  describe 'time range filtering' do
    let(:admin) { create(:member, :admin) }
    let(:in_range_uid) { 'in-range-card' }
    let(:out_of_range_uid) { 'out-of-range-card' }

    before do
      sign_in admin
      now = Time.now
      create(:rejection_card, uid: in_range_uid, timeOf: now - 1.hour)
      create(:rejection_card, uid: out_of_range_uid, timeOf: now - 30.days)
    end

    it 'excludes rejections outside the requested startTime/endTime window' do
      now = Time.now
      # camelCase, exactly as the frontend sends via URLSearchParams
      request_rejections([in_range_uid, out_of_range_uid], time_range: {
        startTime: ((now - 7.days).to_i * 1000).to_s,
        endTime: (now.to_i * 1000).to_s
      })

      expect(response).to have_http_status(:ok)
      uids = JSON.parse(response.body).fetch('rejections').map { |rejection| rejection.fetch('uid') }
      expect(uids).to contain_exactly(in_range_uid)
    end
  end
end
