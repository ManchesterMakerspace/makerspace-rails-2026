require 'rails_helper'

RSpec.describe RejectionCard, type: :model do
  it 'defines its Mongoid collection and fields', :aggregate_failures do
    expect(described_class).to be_mongoid_document
    expect(described_class).to be_stored_in(collection: 'rejections')

    expect(described_class).to have_field(:uid)
    expect(described_class).to have_fields(:holder, :validity).of_type(String)
    expect(described_class).to have_field(:timeOf).of_type(DateTime)
  end

  it "has a valid factory" do
    expect(build(:rejection_card)).to be_valid
  end
end
