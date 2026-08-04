require 'rails_helper'

RSpec.describe Service::EmailTemplate do
  let(:redis_values) { {} }
  let(:drive) { instance_double(Google::Apis::DriveV3::DriveService) }
  let(:metadata) do
    Google::Apis::DriveV3::File.new(
      id: 'doc-123',
      name: 'Reservation reminder',
      mime_type: 'application/vnd.google-apps.document',
      modified_time: Time.zone.parse('2026-08-03 10:00:00')
    )
  end

  before do
    allow(REDIS).to receive(:get) { |key| redis_values[key] }
    allow(REDIS).to receive(:set) { |key, value| redis_values[key] = value; 'OK' }
    allow(REDIS).to receive(:del) { |*keys| keys.each { |key| redis_values.delete(key) } }
    allow(Service::GoogleDrive).to receive(:load_gdrive).and_return(drive)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('DOC_RESERVATION_REMINDER_ID').and_return('doc-123')
    allow(drive).to receive(:get_file).and_return(metadata)
  end

  def export_html(html)
    allow(drive).to receive(:export_file) do |_id, _type, download_dest:|
      download_dest.write(html)
    end
  end

  describe '.render' do
    it 'caches the last valid content and metadata in Redis and sanitizes values' do
      export_html('<html><body><p>Reminder: {{reservation_title}}</p></body></html>')

      result = described_class.render(:reservation_reminder, { reservation_title: '<script>bad()</script>Build' }, format: :text)

      expect(result).to eq('Reminder: &lt;script&gt;bad()&lt;/script&gt;Build')
      cached = JSON.parse(redis_values.fetch('external_template:v1:reservation_reminder:content'))
      expect(cached.dig('metadata', 'name')).to eq('Reservation reminder')
      expect(cached['content']).to include('{{reservation_title}}')
      expect(cached['fetched_at']).to be_present
    end

    it 'uses the cached export without revalidating a valid document on every use' do
      export_html('<html><body>Reminder: {{reservation_title}}</body></html>')

      2.times do
        described_class.render(:reservation_reminder, { reservation_title: 'Lathe' }, format: :text)
      end

      expect(drive).to have_received(:get_file).once
      expect(drive).to have_received(:export_file).once
    end

    it 'preserves template-owned Slack link markup while escaping its label' do
      export_html('<html><body>&lt;{{profile_url}}|{{full_name}}&gt;</body></html>')

      result = described_class.render(
        :reservation_reminder,
        { profile_url: 'https://example.test/members/1', full_name: 'Alice <!channel>' },
        format: :text
      )

      expect(result).to eq('<https://example.test/members/1|Alice &lt;!channel&gt;>')
    end

    it 'escapes member-controlled values in compiled text fallbacks without escaping link structure' do
      result = described_class.render(
        :volunteer_discount_no_subscription,
        {
          profile_url: 'https://example.test/members/1',
          full_name: 'Alice <!channel>',
          member_id: '1'
        },
        fallback: true,
        format: :text
      )

      expect(result).to include('<https://example.test/members/1|Alice &lt;!channel&gt;>')
    end

    it 'allows per-template placeholders followed by common placeholders' do
      expect(described_class.placeholders_for(:reservation_reminder)).to start_with(
        'reservation_title', 'reservation_time', 'resources', 'reservations_url'
      )
      expect(described_class.placeholders_for(:reservation_reminder)).to include(
        'first_name', 'last_name', 'full_name', 'join_date', 'expiration_date', 'slack_username'
      )
    end

    it 'rejects unknown placeholders and evicts the previously valid cache entry' do
      export_html('<html><body>Valid {{reservation_title}}</body></html>')
      described_class.refresh!(:reservation_reminder)
      export_html('<html><body>Bad {{execute_code}}</body></html>')

      expect { described_class.refresh!(:reservation_reminder) }
        .to raise_error(Service::EmailTemplate::InvalidTemplate, /execute_code/)
      expect(redis_values).not_to have_key('external_template:v1:reservation_reminder:content')
      status = JSON.parse(redis_values.fetch('external_template:v1:reservation_reminder:status'))
      expect(status['status']).to eq('invalid')
    end

    it 'evicts invalid cached content so the next use retries Google' do
      key = 'external_template:v1:reservation_reminder:content'
      redis_values[key] = JSON.generate(
        'document_id' => 'doc-123',
        'content' => '<html><body>Bad {{execute_code}}</body></html>'
      )
      variables = {
        reservation_title: 'Lathe', reservation_time: 'Tomorrow', resources: 'Woodshop',
        reservations_url: 'https://example.test/reservations'
      }
      export_html('<html><body>Recovered {{reservation_title}}</body></html>')

      first = described_class.render(:reservation_reminder, variables, fallback: true, format: :text)
      second = described_class.render(:reservation_reminder, variables, fallback: true, format: :text)

      expect(first).to include('Reminder: your reservation *Lathe*')
      expect(second).to eq('Recovered Lathe')
      expect(drive).to have_received(:export_file).once
      expect(redis_values).to have_key(key)
    end

    it 'evicts an empty document, uses the fallback, and checks Google again on each use' do
      export_html('<html><body>Valid {{reservation_title}}</body></html>')
      described_class.refresh!(:reservation_reminder)
      export_html("<html><body> \n\t </body></html>")
      expect { described_class.refresh!(:reservation_reminder) }
        .to raise_error(Service::EmailTemplate::InvalidTemplate, /empty document/)

      results = 2.times.map do
        described_class.render(
          :reservation_reminder,
          {
            reservation_title: 'Lathe', reservation_time: 'Tomorrow', resources: 'Woodshop',
            reservations_url: 'https://example.test/reservations'
          },
          fallback: true,
          format: :text
        )
      end

      expect(results).to all(include('Lathe'))
      expect(drive).to have_received(:export_file).exactly(4).times
      expect(redis_values).not_to have_key('external_template:v1:reservation_reminder:content')
      expect(described_class.status(:reservation_reminder)[:status]).to eq('empty')
    end

    it 'evicts an unreadable document and retries Google before every fallback' do
      export_html('<html><body>Valid {{reservation_title}}</body></html>')
      described_class.refresh!(:reservation_reminder)
      allow(drive).to receive(:get_file).and_raise(StandardError, 'file not found')
      expect { described_class.refresh!(:reservation_reminder) }
        .to raise_error(StandardError, 'file not found')

      results = 2.times.map do
        described_class.render(
          :reservation_reminder,
          {
            reservation_title: 'Lathe', reservation_time: 'Tomorrow', resources: 'Woodshop',
            reservations_url: 'https://example.test/reservations'
          },
          fallback: true,
          format: :text
        )
      end

      expect(results).to all(include('Lathe'))
      expect(drive).to have_received(:get_file).exactly(4).times
      expect(redis_values).not_to have_key('external_template:v1:reservation_reminder:content')
      expect(described_class.status(:reservation_reminder)[:status]).to eq('error')
    end

    it 'uses the compiled fallback when the environment variable is missing' do
      allow(ENV).to receive(:[]).with('DOC_RESERVATION_REMINDER_ID').and_return(nil)

      result = described_class.render(
        :reservation_reminder,
        {
          reservation_title: 'Lathe', reservation_time: 'Tomorrow', resources: 'Woodshop',
          reservations_url: 'https://example.test/reservations'
        },
        fallback: true,
        format: :text
      )

      expect(result).to include('Lathe', '<https://example.test/reservations|member portal>')
    end
  end

  describe '.status' do
    it 'returns an uncached status without calling Google' do
      result = described_class.status(:reservation_reminder)

      expect(result[:status]).to eq('uncached')
      expect(Service::GoogleDrive).not_to have_received(:load_gdrive)
    end
  end

  describe '.sanitize_template_value' do
    it 'normalizes and escapes ASCII-8BIT encoded replacement values' do
      value = "<b>Jo\u0301</b><script>alert(1)</script>".dup.force_encoding(Encoding::ASCII_8BIT)

      expect { described_class.send(:sanitize_template_value, value) }.not_to raise_error
      expect(described_class.send(:sanitize_template_value, value)).to eq(
        '&lt;b&gt;Jó&lt;/b&gt;&lt;script&gt;alert(1)&lt;/script&gt;'
      )
    end
  end
end
