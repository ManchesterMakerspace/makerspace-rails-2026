namespace :shortcodes do
  desc "Create and verify the unique indexes required before short URL allocation"
  task ensure_indexes: :environment do
    Shortcode.create_indexes
    ShortUrl.verify_indexes!
    puts "Shortcode unique indexes verified"
  end
end
