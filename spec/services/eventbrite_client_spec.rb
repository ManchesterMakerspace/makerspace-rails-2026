require 'rails_helper'
RSpec.describe EventbriteIntegration::Client do
  let(:http) { instance_double(Faraday::Connection) }
  before do
    allow(EventbriteIntegration::Configuration).to receive(:token).and_return("test-#{SecureRandom.uuid}")
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return(['org'])
    allow(Faraday).to receive(:new).and_return(http)
  end
  it 'uses unchanged continuation tokens and retains filters' do
    client = described_class.new
    allow(client).to receive(:get).with('organizations/org/events/', { 'name_filter' => 'Weld' }).and_return({ 'pagination' => { 'has_more_items' => true, 'continuation' => 'opaque+/' }, 'events' => [] })
    allow(client).to receive(:get).with('organizations/org/events/', { 'name_filter' => 'Weld', 'continuation' => 'opaque+/' }).and_return({ 'pagination' => { 'has_more_items' => false }, 'events' => [] })
    pages = []
    client.each_page('organizations/org/events/', { 'name_filter' => 'Weld' }) { |_, token| pages << token }
    expect(pages).to eq(['opaque+/', nil])
  end
  it 'allows the fixed current-user organization discovery endpoint without an allowlist' do
    allow(EventbriteIntegration::Configuration).to receive(:organization_ids).and_return([])
    allow(http).to receive(:get).with('users/me/organizations/', {}).and_return(
      double(status: 200, headers: {}, body: '{"organizations":[]}')
    )
    expect(described_class.new.get('users/me/organizations/')).to eq('organizations' => [])
  end

  it 'continues to admit app-generated event, order, attendee, inventory and series paths' do
    allow(http).to receive(:get).and_return(double(status: 200, headers: {}, body: '{"id":"1"}'))
    client = described_class.new
    %w[organizations/org/events/ events/e/orders/ orders/o/ events/e/attendees/a/
       events/e/ticket_classes/ events/e/inventory_tiers/ series/s/events/].each do |path|
      expect(client.get(path)).to eq('id' => '1')
      expect(http).to have_received(:get).with(path, {}).once
    end
  end

  {
    'events//orders/' => ['shape=events//orders/', 'repeated_slash'],
    '/v3/events/123/orders/' => ['shape=/v3/events/<id bytes=3>/orders/', 'leading_slash', 'version_prefix'],
    'events/123/orders' => ['shape=events/<id bytes=3>/orders', 'missing_trailing_slash'],
    'events/bad value/orders/' => ['shape=events/<invalid bytes=9>/orders/', 'whitespace'],
    'events/../orders/' => ['shape=events/<invalid bytes=2>/orders/', 'other_characters'],
    'payments/private-person/' => ['shape=<id bytes=8>/<id bytes=14>/', 'unsupported_namespace']
  }.each do |path, details|
    it "reports only structural diagnostics and makes no request for #{details.last}" do
      expect(http).not_to receive(:get)
      expect(EventbriteIntegration::Lease).not_to receive(:with)
      expect { described_class.new.get(path) }.to raise_error(described_class::InvalidPathError) do |error|
        expect(error).to be_a(ArgumentError)
        details.each { |detail| expect(error.message).to include(detail) }
        expect(error.message).not_to include('123', 'bad value', 'private-person')
      end
    end
  end

  it 'omits URL authorities, dynamic segments, query values and fragments from rejected-path diagnostics' do
    path = "https://person:credential@private.example/v3/events/person@example.com/orders/?name=PrivatePerson#private-fragment"
    expect(http).not_to receive(:get)
    expect { described_class.new.get(path, { 'private-key' => 'private-value' }) }
      .to raise_error(described_class::InvalidPathError) do |error|
        expect(error.message).to include('absolute_url', 'query', 'fragment', 'shape=/v3/events/<invalid bytes=18>/orders/')
        %w[person credential private.example person@example.com name= PrivatePerson private-fragment private-key private-value].each do |value|
          expect(error.message).not_to include(value)
        end
      end
  end

  it 'suppresses the entire shape when configured credentials or private paths appear in raw or encoded input' do
    expect(http).not_to receive(:get)
    allow(EventbriteIntegration::Configuration).to receive(:token).and_return('private+/credential=')
    allow(EventbriteIntegration::Configuration).to receive(:webhook_path).and_return('/events')
    ['/events?x=1', "events/#{CGI.escape('private+/credential=')}/orders/", 'events/x/orders/?key=private+/credential='].each do |path|
      expect { described_class.new.get(path) }.to raise_error(described_class::InvalidPathError) do |error|
        expect(error.message).to include('shape=[REDACTED]', 'sensitive_value')
        expect(error.message).not_to include('/events', 'private', 'credential', 'events/')
      end
    end
  end

  it 'redacts an identifier even when its value matches fixed API vocabulary' do
    expect(http).not_to receive(:get)
    expect { described_class.new.get('events/orders/orders/?extra=private') }
      .to raise_error(described_class::InvalidPathError, /shape=events\/<id bytes=6>\/orders\//)
  end

  it 'bounds malformed, non-string, control-character and invalid-encoding diagnostics without echoing input' do
    expect(http).not_to receive(:get)
    paths = [nil, { 'private' => 'data' }, '', "events/PrivatePerson\n\e\u202e/orders/",
      "events/\xff/orders/".b, "events/#{'private' * 1000}/orders?x=1"]
    paths.each do |path|
      expect { described_class.new.get(path) }.to raise_error(described_class::InvalidPathError) do |error|
        expect(error.message.length).to be <= 530
        expect(error.message).not_to include('PrivatePerson', 'private', 'data')
        expect(error.message).not_to match(/[[:cntrl:]\p{Cf}\p{Zl}\p{Zp}]/)
      end
    end
  end
  it 'fails rather than looping on an unusable continuation' do
    client = described_class.new
    allow(client).to receive(:get).and_return({ 'pagination' => { 'has_more_items' => true } })
    expect { client.each_page('organizations/org/events/') { |_| } }.to raise_error(described_class::ApiError)
  end
  it 'shares a 429 cooldown even with a non-JSON response' do
    allow(http).to receive(:get).and_return(double(status: 429, headers: { 'retry-after' => '120' }, body: 'rate limited'))
    client = described_class.new
    expect { client.get('orders/1/') }.to raise_error(described_class::Deferred) { |e| expect(e.delay).to be >= 120 }
    expect { client.get('orders/1/') }.to raise_error(described_class::Deferred)
    expect(http).to have_received(:get).once
  end
  it 'applies a shared cooldown without Retry-After' do
    allow(http).to receive(:get).and_return(double(status: 429, headers: {}, body: '{}'))
    client = described_class.new
    expect { client.get('orders/1/') }.to raise_error(described_class::Deferred) { |e| expect(e.delay).to be_between(60, 70) }
    expect { described_class.new.get('orders/1/') }.to raise_error(described_class::Deferred)
    expect(http).to have_received(:get).once
  end
  [[3600, 2000], [86_400, 48_000]].each do |seconds, limit|
    it "enforces the rolling #{seconds}-second budget before sending" do
      client = described_class.new
      key = client.instance_variable_get(:@key)
      now = Time.now.to_f
      REDIS.zadd(key, Array.new(limit) { |i| [now - seconds / 2, "call#{i}"] })
      expect(http).not_to receive(:get)
      expect { client.get('orders/1/') }.to raise_error(described_class::Deferred)
    ensure
      REDIS.del(key)
    end
  end
  it 'waits at least half a second after completion across client instances' do
    calls = []
    allow(http).to receive(:get) do
      calls << Process.clock_gettime(Process::CLOCK_MONOTONIC)
      double(status: 200, headers: {}, body: '{"id":"1"}')
    end
    described_class.new.get('orders/1/')
    described_class.new.get('orders/1/')
    expect(calls.last - calls.first).to be >= 0.5
  end
  [302, 401, 403, 503].each do |status|
    it "surfaces #{status} without automatic retries or redirects" do
      allow(http).to receive(:get).and_return(double(status: status, headers: { 'location' => 'https://example.com' }, body: '{}'))
      expect { described_class.new.get('orders/1/') }.to raise_error(described_class::ApiError) { |e| expect(e.status).to eq(status) }
      expect(http).to have_received(:get).once
    end
  end
  it 'never sends a second request while the shared token lease is occupied' do
    client = described_class.new
    EventbriteIntegration::Lease.with(client.instance_variable_get(:@key)) do
      expect(http).not_to receive(:get)
      expect { described_class.new.get('orders/1/') }.to raise_error(described_class::Deferred)
    end
  end

  it 'captures only the sanitized error description in the exception message' do
    description = "There are errors with your arguments: 'status' - Invalid choice 'both'."
    allow(http).to receive(:get).and_return(double(status: 400, headers: {}, body: {
      error: 'ARGUMENTS_ERROR', error_description: description,
      attendees: [{ profile: { name: 'Private Person', email: 'person@example.com' } }]
    }.to_json))
    expect { described_class.new.get('events/1/orders/') }.to raise_error(described_class::ApiError) do |error|
      expect(error.status).to eq(400)
      expect(error.code).to eq('ARGUMENTS_ERROR')
      expect(error.description).to eq(description)
      expect(error.message).to eq("Eventbrite API returned 400 (ARGUMENTS_ERROR): #{description}")
      expect(error.message).not_to include('Private Person', 'person@example.com', 'attendees')
    end
  end

  it 'redacts credentials, private receiver paths, echoed inputs and arbitrary quoted values before capture' do
    credential = 'private+/credential='
    allow(EventbriteIntegration::Configuration).to receive(:token).and_return(credential)
    private_path = "/receiver/#{'s' * 32}"
    allow(EventbriteIntegration::Configuration).to receive(:webhook_path).and_return(private_path)
    description = "Invalid status; #{credential}; #{CGI.escape(credential)}; #{private_path}; #{CGI.escape(private_path)}; " \
      "Bearer hidden-auth-value; https://example.com/private?x=1; person@example.com; 'Private Person'; " \
      "`Multiple\nLines`; opaque-cursor-value"
    allow(http).to receive(:get).and_return(double(status: 400, headers: {}, body: {
      error: 'ARGUMENTS_ERROR', error_description: description
    }.to_json))
    expect { described_class.new.get('events/1/orders/', { 'continuation' => 'opaque-cursor-value' }) }
      .to raise_error(described_class::ApiError) do |error|
        expect(error.message).to include('Invalid status')
        [credential, CGI.escape(credential), private_path, CGI.escape(private_path), 'hidden-auth-value',
         'https://example.com', 'person@example.com', 'Private Person', 'Multiple', 'opaque-cursor-value'].each do |value|
          expect(error.message).not_to include(value)
        end
      end
  end

  it 'omits descriptions containing sensitive field details, including unquoted names' do
    error = described_class::ApiError.new(400, 'ARGUMENTS_ERROR', description: 'Invalid buyer name: Private Person')
    expect(error.description).to eq('[REDACTED: sensitive validation details]')
    expect(error.message).not_to include('Private Person')
  end

  it 'bounds descriptions and removes control characters and bidi formatting' do
    error = described_class::ApiError.new(400, 'ARGUMENTS_ERROR', description: "Invalid status\r\n\e[31m\u202e\u2028\u2029 " * 100)
    expect(error.description.length).to be <= 512
    expect(error.description).to end_with('...')
    expect(error.description).not_to match(/[[:cntrl:]\p{Cf}\p{Zl}\p{Zp}]/)
    huge = described_class::ApiError.new(400, 'ARGUMENTS_ERROR', description: 'x' * 16_385)
    expect(huge.description).to eq('[OMITTED: oversized error description]')
  end

  [nil, '', [], { 'private' => 'data' }].each do |description|
    it "keeps the original error format for a missing or malformed description #{description.class}" do
      error = described_class::ApiError.new(400, 'ARGUMENTS_ERROR', description: description)
      expect(error.message).to eq('Eventbrite API returned 400 (ARGUMENTS_ERROR)')
    end
  end

  it 'redacts configured secrets even when they happen to match safe API vocabulary' do
    allow(EventbriteIntegration::Configuration).to receive(:token).and_return('both')
    error = described_class::ApiError.new(400, 'ARGUMENTS_ERROR', description: "status invalid: 'both'")
    expect(error.message).not_to include('both')
  end
end
