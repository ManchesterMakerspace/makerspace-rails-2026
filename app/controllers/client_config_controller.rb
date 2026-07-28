# GET /api/config
#
# Public endpoint — no authentication required.
<<<<<<< HEAD
# Returns runtime configuration needed by the React client before login,
# including public integration URLs. Serves values from environment variables
# so deployment-specific values never need to be compiled into the JS bundle.
=======
# Returns runtime configuration needed by the React client before login.
# Serves values from environment variables so 'secrets' never touch git or the
# built JS bundle.
>>>>>>> 1e7b71bc16c8a0b6bfbd6a64a4ea99f8443febca
#
# Note that the firebase_api_key and the other firebase_ values are NOT secret.
#
# Also FIREBASE_AUTH_DOMAIN (authDomain) can only be a single string, not a list
#
class ClientConfigController < ApplicationController
  def index
  firebase_auth_domain=ENV['FIREBASE_PROJECT_ID'].to_s + ".firebaseapp.com"

  firebase_auth_type="signInWithPopup"
  if ENV['FIREBASE_AUTH_TYPE'].present?
    firebase_auth_type=ENV['FIREBASE_AUTH_TYPE']
  end

  if ENV['FIREBASE_AUTH_DOMAIN'].present?
    firebase_auth_domain=ENV['FIREBASE_AUTH_DOMAIN']
#  else
#    $stderr.puts "[config] Missing mandatory environment variable FIREBASE_AUTH_DOMAIN, using fallback #{firebase_auth_domain}"
  end

    render json: {
      firebase_api_key:    ENV['FIREBASE_API_KEY'].to_s,
      firebase_project_id: ENV['FIREBASE_PROJECT_ID'].to_s,
<<<<<<< HEAD
      wiki_url:            WikiUrlBuilder.base_url,
=======
      firebase_auth_domain: firebase_auth_domain,
      firebase_auth_type: firebase_auth_type
>>>>>>> 1e7b71bc16c8a0b6bfbd6a64a4ea99f8443febca
    }, status: :ok
  end
end
