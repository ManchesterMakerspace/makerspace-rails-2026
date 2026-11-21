module VolunteerValidationErrors
  extend ActiveSupport::Concern

  included do
    rescue_from Mongoid::Errors::Validations, with: :render_volunteer_validation_errors
  end

  private

  def render_volunteer_validation_errors(error)
    errors = error.document.errors
    message = errors.full_messages.join(', ')
    slack_alert(:unprocessable_content, 422, message)
    body = ::Error::Helpers::Render.json(:unprocessable_content, 422, message).merge('errors' => errors.to_hash)
    render json: body, status: :unprocessable_content
  end
end
