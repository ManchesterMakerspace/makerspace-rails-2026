require 'rails_helper'

describe Counter, type: :model do
  it 'atomically increments a named sequence' do
    first_id = described_class.next_sequence_id('tickets')
    second_id = described_class.next_sequence_id('tickets')

    expect(first_id).to be_an(Integer)
    expect(second_id).to be_an(Integer)
    expect(second_id).to be > first_id
  end
end
