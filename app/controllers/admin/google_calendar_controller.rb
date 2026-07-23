class Admin::GoogleCalendarController < ApplicationController
  before_action :authenticate_member!
  before_action :authorize_calendar_configuration

  def colors
    render json: { colors: Service::GoogleWorkspace.calendar_colors.first(24) }
  rescue Google::Apis::Error => error
    raise ::Error::UnprocessableEntity.new(
      "Google Calendar colors could not be loaded: #{error.message}"
    )
  end

  private

  def authorize_calendar_configuration
    unless is_admin? || is_board_member? || is_resource_manager?
      raise ::Error::Forbidden.new("You are not authorized to configure shop reservation colors")
    end
  end
end
