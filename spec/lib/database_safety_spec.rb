require 'rails_helper'

RSpec.describe Service::DatabaseSafety do
  it 'allows destructive operations for a recognized test database URI' do
    expect(
      described_class.ensure_safe_mlab_uri!(
        operation: 'test reset',
        mlab_uri: 'mongodb://database.example.com/makerspace_test'
      )
    ).to be(true)
  end

  it 'refuses destructive operations for an unrecognized database URI' do
    expect do
      described_class.ensure_safe_mlab_uri!(
        operation: 'test reset',
        mlab_uri: 'mongodb://database.example.com/makerspace'
      )
    end.to raise_error(RuntimeError, /Refusing to run test reset/)
  end

  it 'refuses destructive operations when MLAB_URI is absent' do
    expect do
      described_class.ensure_safe_mlab_uri!(operation: 'test reset', mlab_uri: nil)
    end.to raise_error(RuntimeError, /MLAB_URI is not set/)
  end
end
