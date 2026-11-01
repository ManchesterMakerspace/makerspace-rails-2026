require 'rails_helper'

# A spot is held until staff confirm it is empty: vacating and awaiting_verification still occupy it.
RSpec.describe Rental, 'held statuses' do
  let(:rental_type) { RentalType.create!(display_name: 'Tote') }
  let(:spot) { RentalSpot.create!(number: 'BL-Tote-9', location: 'Back shop', rental_type_id: rental_type.id.to_s) }

  def rent(status)
    create(:rental, number: spot.number, status: status)
  end

  it 'accepts awaiting_verification as a status' do
    expect(build(:rental, status: 'awaiting_verification')).to be_valid
  end

  %w[active pending vacating awaiting_verification].each do |status|
    it "keeps the spot unavailable while a rental is #{status}" do
      rent(status)

      expect(spot.reload.available?).to be(false)
    end
  end

  it 'releases the spot once the rental is cancelled' do
    rental = rent('awaiting_verification')
    rental.update!(status: 'cancelled')

    expect(spot.reload.available?).to be(true)
  end

  it 'does not allow a second held rental on the same number while one is awaiting verification' do
    rent('awaiting_verification')

    expect(build(:rental, number: spot.number, status: 'active')).not_to be_valid
  end
end
