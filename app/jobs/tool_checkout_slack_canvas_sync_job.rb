class ToolCheckoutSlackCanvasSyncJob < ApplicationJob
  queue_as :default

  def perform(shop_id)
    Service::ToolCheckoutSlackCanvas.sync!(Shop.find(shop_id))
  rescue Mongoid::Errors::DocumentNotFound
    nil
  rescue => error
    message = "[ToolCheckoutSlackCanvasSyncJobError] shop_id=#{shop_id} " \
      "error=#{Service::SlackConnector.format_api_error(error)}"
    $stderr.puts(message)
    Rails.logger.error(message)
    Honeybadger.notify(error) if defined?(Honeybadger)
    raise
  end
end
