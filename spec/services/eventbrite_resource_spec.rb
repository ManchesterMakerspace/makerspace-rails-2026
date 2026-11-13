require 'rails_helper'
RSpec.describe EventbriteIntegration::Resource do
  it 'accepts composite opaque IDs and nested ticket/attendee resources' do
    expect(described_class.parse('https://www.eventbriteapi.com/v3/events/e-1/attendees/123-1/')).to include('id' => '123-1', 'event_id' => 'e-1')
    expect(described_class.parse('https://www.eventbriteapi.com/v3/events/e-1/ticket_classes/t-1/')['type']).to eq('ticket_class')
  end
  it 'rejects arbitrary URLs, credentials, query strings and ambiguous paths' do
    %w[http://www.eventbriteapi.com/v3/orders/1/ https://evil.test/v3/orders/1/ https://www.eventbriteapi.com.evil.test/v3/orders/1/ https://user@www.eventbriteapi.com/v3/orders/1/ https://www.eventbriteapi.com/v3/orders/1/?token=x https://www.eventbriteapi.com/v3/orders/%2e%2e/].each do |url|
      expect { described_class.parse(url) }.to raise_error(ArgumentError)
    end
  end
end
