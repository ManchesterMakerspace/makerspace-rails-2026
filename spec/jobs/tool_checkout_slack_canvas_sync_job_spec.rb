require "rails_helper"

RSpec.describe ToolCheckoutSlackCanvasSyncJob do
  it "no-ops when the shop no longer exists (Mongoid raise_not_found_error is false)" do
    shop = create(:shop)
    allow(Service::ToolCheckoutSlackCanvas).to receive(:sync!)
    missing_id = shop.id.to_s
    shop.destroy

    expect { described_class.new.perform(missing_id) }.not_to raise_error
    expect(Service::ToolCheckoutSlackCanvas).not_to have_received(:sync!)
  end
end
