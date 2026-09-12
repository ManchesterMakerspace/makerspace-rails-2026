namespace :fix_tickets do
  desc 'Create repair ticket indexes (required before enabling tickets)'
  task ensure_indexes: :environment do
    [FixTicket, FixTicketEvent, FixTicketReveal].each(&:create_indexes)
  end
  desc 'Recover pending repair-ticket notifications; run every five minutes'
  task recover_deliveries: :environment do
    FixTicketDeliveryRecoveryJob.perform_now
  end
end
