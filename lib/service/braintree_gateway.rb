module Service
  module BraintreeGateway
    def self.connect_gateway
      Braintree::Gateway.new(
        :environment => ENV["BT_ENV"]&.to_sym,
        :merchant_id => ENV["BT_MERCHANT_ID"],
        :public_key => ENV["BT_PUBLIC_KEY"],
        :private_key => ENV['BT_PRIVATE_KEY'],
        :http_open_timeout => ENV.fetch("BRAINTREE_OPEN_TIMEOUT", 5).to_i,
        :http_read_timeout => ENV.fetch("BRAINTREE_READ_TIMEOUT", 20).to_i,
      )
    end

    def connect_gateway
      ::Service::BraintreeGateway.connect_gateway
    end
  end
end
