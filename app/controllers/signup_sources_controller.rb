class SignupSourcesController < ApplicationController
  before_action :authenticate_member!, only: :update
  def events
    render json: EventbriteEvent.signup_choices.map { |event| { id: event.id.to_s, name: event.name, startsAt: event.starts_at.iso8601, timezone: event.timezone } }, adapter: :attributes
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
