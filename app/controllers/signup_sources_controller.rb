class SignupSourcesController < ApplicationController
  before_action :authenticate_member!, only: :update
  def events
    render json: EventbriteIntegration::DisplayCache.signup_choices, adapter: :attributes
  end
  def update
    member = current_member
    if member.signup_source_prompt_pending
      member.update!(params.permit(:signup_source, :signup_source_detail, :signup_eventbrite_event_id).to_h.merge(
        signup_source_prompt_pending: false, signup_source_asked_at: Time.current))
    end
    render json: member, adapter: :attributes
  end
end
