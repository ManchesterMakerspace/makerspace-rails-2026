require 'rails_helper'

RSpec.describe ReservationDisplayQuery do
  include ReservationReadMeasurement

  let(:zone) { ReservationService::ZONE }
  let(:shop) { create(:shop) }
  let(:member) { create(:member, :current, firstname: 'Ada', lastname: 'Lovelace') }

  it 'loads only names without running membership initialization callbacks' do
    id = member.id
    expect_any_instance_of(Member).not_to receive(:verify_group_expiry)
    measurement = measure_reservation_reads do
      expect(described_class.member_names([id, id, BSON::ObjectId.new])).to eq(id.to_s => 'Ada Lovelace')
    end
    expect(measurement[:commands]).to eq([['find', 'members']])
  end

  it 'skips empty member and blackout lookups' do
    measurement = measure_reservation_reads do
      expect(described_class.member_names([])).to eq({})
      expect(described_class.blackouts(shop_ids: [], start_at: Time.current, end_at: 1.day.from_now)).to eq([])
    end
    expect(measurement[:commands]).to be_empty
  end

  it 'preserves the member default scope when projecting names' do
    existing = member
    existing.set(merged_at: Time.current)
    expect(described_class.member_names([existing.id])).to eq({})
  end

  [Date.new(2026, 3, 8), Date.new(2026, 11, 1)].each do |date|
    it "retains overnight and unbounded blackouts while pruning impossible rules on #{date}" do
      previous = date - 1.day
      overnight = create(:reservation_blackout, shop: shop, created_by: member, recurrence: 'daily',
        start_time: '23:30', end_time: '00:30', start_date: previous, end_date: previous)
      unbounded = create(:reservation_blackout, shop: shop, created_by: member, recurrence: 'daily',
        start_time: '12:00', end_time: '13:00')
      create(:reservation_blackout, shop: shop, created_by: member, recurrence: 'daily',
        start_date: date + 2.days)
      create(:reservation_blackout, shop: shop, created_by: member, recurrence: 'daily',
        end_date: date - 2.days)
      other_shop = create(:shop)
      create(:reservation_blackout, shop: other_shop, created_by: member, recurrence: 'daily')
      following = date + 1.day
      start_at = zone.local(date.year, date.month, date.day)
      end_at = zone.local(following.year, following.month, following.day)
      candidates = described_class.blackouts(shop_ids: [shop.id], start_at: start_at, end_at: end_at)

      expect(candidates.map(&:id)).to contain_exactly(overnight.id, unbounded.id)
      occurrences = candidates.flat_map { |blackout| blackout.occurrences_overlapping(start_at, end_at) }
      expect(occurrences.map { |occurrence| occurrence[:blackout].id }).to contain_exactly(overnight.id, unbounded.id)
      expect(occurrences.find { |occurrence| occurrence[:blackout].id == overnight.id }[:end_at])
        .to eq(start_at + 30.minutes)
    end
  end
end
