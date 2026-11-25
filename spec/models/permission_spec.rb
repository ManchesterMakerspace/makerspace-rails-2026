require 'rails_helper'

RSpec.describe Permission, type: :model do

    it 'defines its Mongoid collection and fields', :aggregate_failures do
      expect(described_class).to be_mongoid_document
      expect(described_class).to be_stored_in(collection: 'permissions')
      expect(described_class).to have_fields(:name, :enabled)
    end

    it { is_expected.to belong_to(:member) }

    describe "public methods" do
      it "Get list of exiting permission names" do
        create(:permission, name: :bar)
        create(:permission, name: :foo, enabled: true)
        create(:permission, name: :baz, enabled: true)
        create(:permission, name: :foo)
        expect(Permission.list_permissions).to contain_exactly('foo', 'bar', 'baz')
      end
    end
end
