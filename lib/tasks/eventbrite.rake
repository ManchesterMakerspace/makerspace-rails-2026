namespace :eventbrite do
  desc 'Announce upcoming public Eventbrite events; optional positive days defaults to 24 hours'
  task :announce_upcoming, [:days] => :environment do |_, args|
    days = args[:days].presence || '1'
    raise ArgumentError, 'days must be a positive whole number' unless days.match?(/\A[1-9][0-9]*\z/)
    deliveries = EventbriteIntegration::Announcements.new(EventbriteIntegration::Backfill::WaitingClient.new).upcoming(days)
    counts = Hash.new(0)
    deliveries.each do |delivery|
      previously_posted = delivery.ts.present?
      EventbriteSlackDeliveryJob.perform_now(delivery.id.to_s)
      delivery.reload
      outcome = if delivery.failed_at then :failed
      elsif delivery.expired then :skipped
      elsif delivery.due_at then :deferred
      elsif previously_posted then :updated
      else :posted
      end
      counts[outcome] += 1
    end
    puts %i[posted updated skipped deferred failed].map { |key| "#{key}=#{counts[key]}" }.join(' ')
    raise 'Eventbrite announcements incomplete; inspect eventbrite_slack_deliveries' if counts[:failed] + counts[:deferred] > 0
  end

  %w[events orders attendees].each do |kind|
    desc "Backfill Eventbrite #{kind}; NAME_INCLUDE/NAME_EXCLUDE, CHANGED_SINCE and RESUME_RUN_ID documented in docs/eventbrite.md"
    task "backfill_#{kind}" => :environment do
      backfill = EventbriteIntegration::Backfill.new(kind)
      run = backfill.call
      puts "Eventbrite run #{run.id}: processed=#{run.processed} skipped=#{run.skipped} failed=0"
    rescue StandardError => error
      run = backfill&.run
      warn "Eventbrite run #{run.id}: processed=#{run.processed} skipped=#{run.skipped} failed=#{run.failed}" if run
      warn "Eventbrite backfill incomplete: #{error.class.name}. Inspect eventbrite_sync_runs and resume with RESUME_RUN_ID."
      raise
    end
  end
  desc 'Retry failed Eventbrite deliveries after correcting configuration/provider errors'
  task retry_failed: :environment do
    EventbriteIntegration::Configuration.validate!
    count = EventbriteWebhookDelivery.where(:failed_at.ne => nil).update_all(failed_at: nil, attempts: 0, due_at: Time.current)
    slack_count = EventbriteSlackDelivery.where(:failed_at.ne => nil, sending_at: nil).update_all(failed_at: nil, attempts: 0, due_at: Time.current)
    puts "Reset #{slack_count} known Slack failures; ambiguous sends require receipt reconciliation"
    puts "Reset #{count} failed Eventbrite deliveries; recovery will retry them"
  end
end
