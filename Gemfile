source 'https://rubygems.org'
ruby '3.2.9'

gem 'rails', '~> 7.2.0'
gem 'rack-cors', '~> 2.0'
gem 'puma', '~> 6.0'
gem 'active_model_serializers', '~> 0.10.15'
gem 'dotenv-rails'
gem 'concurrent-ruby', '~> 1.3'

# Redis
gem 'redis', '~> 5.0'
gem 'connection_pool', '~> 2.4'
gem 'redis-actionpack'

# Authentication
gem 'devise', '~> 4.9'
gem 'rotp',    '~> 6.0'
gem 'rqrcode', '~> 2.0'
gem 'bcrypt'

# MongoDB
gem 'mongoid', '~> 8.0'
gem 'mongoid_search', '~> 0.4'

# Payments
gem 'paypal-sdk-rest', '~> 1.7'
gem 'braintree', '~> 4.0'
gem 'slack-ruby-client', '~> 2.0'

# Google Drive
gem 'multi_json', '>= 1.14.1'
gem 'google-apis-drive_v3'
gem 'google-apis-sheets_v4'

gem 'mini_magick', '~> 4.11'
gem 'sprockets-rails'
gem 'mime-types', '~> 3.5'
gem 'rest-client', '~> 2.1'
gem 'git', '~> 2.0'
gem 'rswag-api', '~> 2.14'
gem 'rswag-ui', '~> 2.14'

# PDF generation
gem 'wicked_pdf', '~> 2.0'
gem 'wkhtmltopdf-binary'

group :test do
  gem 'rspec-rails', '~> 6.0'
  gem 'mongoid-rspec', '~> 4.1'
  gem 'database_cleaner-mongoid'
  gem 'rails-controller-testing'
  gem 'simplecov'
  gem 'rswag-specs', '~> 2.14'
end

group :development do
  gem 'listen', '~> 3.8'
end

group :development, :test do
  gem 'debug'
  gem 'factory_bot_rails'
end

gem 'tzinfo-data', platforms: [:mingw, :mswin, :x64_mingw, :jruby]
gem 'honeybadger', '~> 5.28'
