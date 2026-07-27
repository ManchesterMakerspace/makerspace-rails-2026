class CalendarColorRefreshJob < ApplicationJob
  queue_as :integrations
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform
    Service::GoogleWorkspace.send(:build_color_cache_payload)
  end
end
