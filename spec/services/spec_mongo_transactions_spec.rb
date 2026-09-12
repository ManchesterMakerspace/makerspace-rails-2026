require 'rails_helper'

RSpec.describe SpecMongoTransactions do
  it 'skips standalone servers, even when logical sessions are available' do
    expect(described_class.supported_topology?('logicalSessionTimeoutMinutes' => 30, 'maxWireVersion' => 25)).to be(false)
  end

  it 'accepts replica sets and transaction-capable sharded clusters' do
    expect(described_class.supported_topology?('logicalSessionTimeoutMinutes' => 30, 'maxWireVersion' => 7, 'setName' => 'test')).to be(true)
    expect(described_class.supported_topology?('logicalSessionTimeoutMinutes' => 30, 'maxWireVersion' => 8, 'msg' => 'isdbgrid')).to be(true)
  end

  it 'rejects topologies without sessions or sufficiently recent transaction support' do
    expect(described_class.supported_topology?('maxWireVersion' => 25, 'setName' => 'test')).to be(false)
    expect(described_class.supported_topology?('logicalSessionTimeoutMinutes' => 30, 'maxWireVersion' => 7, 'msg' => 'isdbgrid')).to be(false)
  end
end
