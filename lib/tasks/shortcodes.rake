namespace :shortcodes do
  desc "Create and verify the unique indexes required before short URL allocation"
  task ensure_indexes: :environment do
    Shortcode.create_indexes
    ShortUrl.verify_indexes!
    puts "Shortcode unique indexes verified"
  end
end

# Run after Mongoid finishes its normal index creation, so the deployment job
# also verifies the indexes required for safe shortcode allocation.
Rake::Task["db:mongoid:create_indexes"].enhance do
  Rake::Task["shortcodes:ensure_indexes"].invoke
end
