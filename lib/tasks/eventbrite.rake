namespace :eventbrite do
  desc 'Announce upcoming public Eventbrite events; optional positive days defaults to 24 hours'
  task :announce_upcoming, [:days] => :environment do |_, args|
    days = args[:days].presence || '1'
    raise ArgumentError, 'days must be a positive whole number' unless days.match?(/\A[1-9][0-9]*\z/)
    configured_channel = SystemConfig.get('slack_channel_upcoming_events').presence || 'upcoming-events'
    warn "Eventbrite Slack routing: #{JSON.generate(
      mode: Service::SlackConnector.message_destination_mode,
      configured_channel: configured_channel,
      effective_channel: Service::SlackConnector.safe_channel(configured_channel)
    )} (new posts; existing messages retain their saved channel)"
    deliveries = EventbriteIntegration::Announcements.new(EventbriteIntegration::Backfill::WaitingClient.new).upcoming(days)
    counts = Hash.new(0)
    deliveries.each do |delivery|
      previously_posted = delivery.ts.present?
      previously_failed = delivery.failed_at.present?
      EventbriteSlackDeliveryJob.perform_now(delivery.id.to_s)
      delivery.reload
      outcome = if delivery.failed_at then :failed
      elsif delivery.expired then :skipped
      elsif delivery.due_at then :deferred
      elsif previously_posted then :updated
      else :posted
      end
      counts[outcome] += 1
      if %i[failed deferred].include?(outcome)
        warn "Eventbrite Slack #{outcome}: #{JSON.generate(
          id: delivery.id.to_s, event_ids: delivery.event_ids, mode: delivery.mode,
          previously_failed: previously_failed, attempts: delivery.attempts,
          failed_at: delivery.failed_at, due_at: delivery.due_at,
          sending_at: delivery.sending_at, ts: delivery.ts, last_error: delivery.last_error
        )}"
      end
    end
    puts %i[posted updated skipped deferred failed].map { |key| "#{key}=#{counts[key]}" }.join(' ')
    if counts[:failed] > 0
      warn 'Failed records are not retried by announce_upcoming. Correct the reported cause, then run bundle exec rake eventbrite:retry_failed for known failures.'
      warn 'AMBIGUOUS_SEND or sending_at without ts requires checking Slack and reconciling the receipt before retrying; see docs/eventbrite.md.'
    end
    raise 'Eventbrite announcements incomplete; see delivery details above and docs/eventbrite.md' if counts[:failed] + counts[:deferred] > 0
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
    count = EventbriteWebhookDelivery.where(:failed_at.ne => nil).update_all(failed_at: nil, attempts: 0, due_at: Time.current).modified_count
    slack_count = EventbriteSlackDelivery.where(:failed_at.ne => nil, sending_at: nil).update_all(failed_at: nil, attempts: 0, due_at: Time.current).modified_count
    puts "Reset #{slack_count} known Slack failures; ambiguous sends require receipt reconciliation"
    puts "Reset #{count} failed Eventbrite deliveries; recovery will retry them"
  end
end
