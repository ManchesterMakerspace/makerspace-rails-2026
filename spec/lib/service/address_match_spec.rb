require 'rails_helper'

RSpec.describe Service::AddressMatch do
  def same?(street_a, postal_a, street_b, postal_b)
    described_class.same?(street_a, postal_a, street_b, postal_b)
  end

  it 'ignores case, punctuation and St/Street style words' do
    expect(same?('12 Main St', '03101', '12 main street', '03101')).to be(true)
    expect(same?('12 Main St.', '03101', '12 MAIN STREET', '03101')).to be(true)
    expect(same?('400 Elm Avenue', '03101', '400 elm ave', '03101')).to be(true)
    expect(same?('9 Maple Rd', '03101', '9 Maple Road', '03101')).to be(true)
    expect(same?('55 N Main St', '03101', '55 North Main Street', '03101')).to be(true)
  end

  it 'ignores a unit written into the street line' do
    expect(same?('12 Main St Apt 3', '03101', '12 Main St', '03101')).to be(true)
    expect(same?('12 Main St #4B', '03101', '12 Main Street, Unit 2', '03101')).to be(true)
  end

  it 'compares only the first five digits of the postal code' do
    expect(same?('12 Main St', '03101-1234', '12 Main St', '03101')).to be(true)
  end

  it 'is strict about the street number, the street name and the postal code' do
    expect(same?('12 Main St', '03101', '14 Main St', '03101')).to be(false)
    expect(same?('12 Main St', '03101', '12 Maine St', '03101')).to be(false)
    expect(same?('12 Main St', '03101', '12 Main Ave', '03101')).to be(false)
    expect(same?('12 Main St', '03101', '12 Main St', '03102')).to be(false)
  end

  it 'never matches a blank street or a blank postal code' do
    expect(same?('', '03101', '', '03101')).to be(false)
    expect(same?(nil, nil, nil, nil)).to be(false)
    expect(same?('12 Main St', '', '12 Main St', '')).to be(false)
  end

  it 'folds accents' do
    expect(same?('7 Rue Bérubé', '03101', '7 rue berube', '03101')).to be(true)
  end

  it 'describes an address for messages' do
    member = Member.new(address_street: '12 Main St', address_postal_code: '03101')
    expect(described_class.describe(member)).to eq('12 Main St, 03101')
    expect(described_class.describe(Member.new)).to eq('no address on file')
  end
end
