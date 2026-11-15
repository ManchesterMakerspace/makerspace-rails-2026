# Hide the secret URL before Rails request logging and instrumentation run.
# Reverse proxies must apply the equivalent access-log exclusion (see operator docs).
class EventbriteWebhookPrivacy
  def initialize(app) = (@app = app)
  def call(env)
    secret = ENV['EVENTBRITE_WEBHOOK_PATH'].to_s.strip
    if secret.present? && env['PATH_INFO'] == secret && EventbriteIntegration::Configuration.valid_webhook_path?
      env['eventbrite.private_receiver'] = true
      env['PATH_INFO'] = '/__eventbrite_receiver__'
      env['REQUEST_URI'] = '/__eventbrite_receiver__'
      env['ORIGINAL_FULLPATH'] = '/__eventbrite_receiver__'
      env['QUERY_STRING'] = ''
    end
    @app.call(env)
  end
end
