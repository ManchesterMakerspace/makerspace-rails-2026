# Addition to app/controllers/slack/commands_controller.rb
#
# Add this action alongside the existing `checkout` action.
# Also add to config/routes.rb inside `namespace :slack`:
#   post '/commands/volunteer', to: 'commands#volunteer'
#
# The /volunteer slash command must be configured in the Slack app dashboard
# to POST to: https://<your-domain>/slack/commands/volunteer

  def volunteer
    SlackVolunteerJob.perform_later(params.to_unsafe_h.stringify_keys)

    render json: {
      response_type: 'ephemeral',
      text: 'Processing your volunteer command...'
    }
  end
