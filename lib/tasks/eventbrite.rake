namespace :eventbrite do
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
    puts "Reset #{count} failed Eventbrite deliveries; recovery will retry them"
  end
end
