# Only capability-dependent examples are optional on standalone MongoDB.
# Connection/authentication failures and failures inside supported transactions
# remain real failures; never blanket-rescue a failing example.
module SpecMongoTransactions
  def self.available?
    return @available if defined?(@available)
    hello = Mongoid.default_client.database.command(hello: 1).first
    @available = supported_topology?(hello)
  end

  def self.supported_topology?(hello)
    return false unless hello['logicalSessionTimeoutMinutes']
    (hello['setName'].present? && hello['maxWireVersion'].to_i >= 7) ||
      (hello['msg'] == 'isdbgrid' && hello['maxWireVersion'].to_i >= 8)
  end
end

RSpec.configure do |config|
  config.prepend_before(:each, requires_transactions: true) do
    skip 'Optional: requires MongoDB transactions (replica set or supported sharded cluster)' unless SpecMongoTransactions.available?
  end
end
