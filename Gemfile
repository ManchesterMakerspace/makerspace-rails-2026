source 'https://rubygems.org'
ruby '~> 3.4.0'

# Explicit for Ruby 3.4 forward-compatibility — these become bundled
# gems (not default) in Ruby 3.4, and are used directly in
# firebase_auth_controller.rb, totp_service.rb, and lib/service/analytics.rb.
gem 'base64'
gem 'csv'

gem 'railties', '8.0.0'
gem 'activemodel', '8.0.0'
gem 'activejob', '8.0.0'
gem 'actionpack', '8.0.0'
gem 'actionview', '8.0.0'
gem 'actionmailer', '8.0.0'
gem 'rack-cors', '~> 3.0'
gem 'puma', '~> 8.0'
gem 'active_model_serializers', '~> 0.10.15'
gem 'dotenv-rails'
# Redis
gem 'redis', '~> 5.0'
gem 'connection_pool', '~> 2.4'
# Sidekiq 7 remains compatible with pre-Redis-7 deployments. Upgrade to
# Sidekiq 8 only after the production Redis server has been verified as 7+.
gem 'sidekiq', '~> 7.3'
# Authentication
gem 'devise', '~> 5.0'
gem 'nokogiri', '~> 1.19.4'
gem 'rotp',    '~> 6.0'
gem 'rqrcode', '~> 3.2'
gem 'bcrypt', '~> 3.1'
# MongoDB
gem 'mongoid', '~> 8.0'
gem 'mongoid_search', '~> 0.4'
# Payments
gem 'paypal-sdk-rest', '~> 1.7'
gem 'braintree', '~> 4.39'
gem 'slack-ruby-client', '~> 2.0'
# Google Drive
gem 'faraday', '~> 2.14'
gem 'google-apis-drive_v3', require: false
gem 'google-apis-sheets_v4', require: false
gem 'google-apis-admin_directory_v1', require: false
gem 'google-apis-calendar_v3', require: false
gem 'sprockets-rails'
# Release/integration rake tasks still use ruby-git; do not load it in web/worker boots.
gem 'git', '~> 4.4', require: false
gem 'rswag-api', '~> 2.14'
gem 'rswag-ui', '~> 2.14'
# PDF generation
gem 'wicked_pdf', '~> 2.8', require: false
gem 'wkhtmltopdf-binary', '~> 0.12.6', require: false
group :test do
  gem 'rspec-rails', '~> 7.1'
  gem 'mongoid-rspec', '~> 4.1'
  gem 'database_cleaner-mongoid'
  gem 'simplecov', '~> 1.0'
  gem 'rswag-specs', '~> 2.14'
end
group :development do
  gem 'listen', '~> 3.8'
end
group :development, :test do
  gem 'debug'
  gem 'factory_bot_rails', '~> 6.0'
end
gem 'tzinfo-data', platforms: [:mingw, :mswin, :x64_mingw, :jruby]
gem 'honeybadger', '~> 6.9'
gem 'valid_email2'
gem 'cloudflare-rails'
