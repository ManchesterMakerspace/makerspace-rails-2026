# GET /api/config
#
# Public endpoint — no authentication required.
# Returns runtime configuration needed by the React client before login,
# including public integration URLs. Serves values from environment variables
# so deployment-specific values never need to be compiled into the JS bundle.
#
class ClientConfigController < ApplicationController
  def index
    render json: {
      firebase_api_key:    ENV['FIREBASE_API_KEY'].to_s,
      firebase_project_id: ENV['FIREBASE_PROJECT_ID'].to_s,
      wiki_url:            WikiUrlBuilder.base_url,
    }, status: :ok
  end
end
