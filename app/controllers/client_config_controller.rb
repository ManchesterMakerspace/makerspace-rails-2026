# GET /api/config
#
# Public endpoint — no authentication required.
# Returns public runtime configuration needed by the React client before login.
# These deployment-specific values do not need to be compiled into the JS
# bundle. Firebase client configuration values are identifiers, not secrets.
#
class ClientConfigController < ApplicationController
  def index
    firebase_auth_domain =
      ENV["FIREBASE_AUTH_DOMAIN"].presence ||
      "#{ENV['FIREBASE_PROJECT_ID']}.firebaseapp.com"
    firebase_auth_type =
      ENV["FIREBASE_AUTH_TYPE"].presence || "signInWithPopup"

    render json: {
      firebase_api_key: ENV["FIREBASE_API_KEY"].to_s,
      firebase_project_id: ENV["FIREBASE_PROJECT_ID"].to_s,
      firebase_auth_domain: firebase_auth_domain,
      firebase_auth_type: firebase_auth_type,
      wiki_url: WikiUrlBuilder.base_url
    }, status: :ok
  end
end
