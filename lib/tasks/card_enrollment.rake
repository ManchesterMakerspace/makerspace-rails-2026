namespace :data do
  desc 'Create non-destructive native enrollment indexes; requires duplicate review on failure'
  task ensure_card_enrollment_indexes: :environment do
    NfcCardEnrollment.create_indexes
  end
end
