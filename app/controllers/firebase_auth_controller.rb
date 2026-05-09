require 'net/http'
require 'json'

# POST /api/auth/firebase_login
#
# Accepts a Firebase ID token from the React client, verifies it against
# Google's public keys, finds or creates a Member record, and creates a
# Devise session — exactly like a normal password login but using Firebase
# as the identity provider.
#
# Env vars required:
#   FIREBASE_PROJECT_ID — your Firebase project ID
#
class FirebaseAuthController < ApplicationController
  GOOGLE_CERTS_URL = 'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com'.freeze

  def login
    id_token = params[:id_token]
    return render json: { message: 'Missing id_token' }, status: :bad_request if id_token.blank?

    payload = verify_firebase_token(id_token)
    return render json: { message: 'Invalid or expired token' }, status: :unauthorized if payload.nil?

    firebase_uid   = payload['sub']
    email          = payload['email']
    email_verified = payload['email_verified']

    return render json: { message: 'Email not verified with provider' }, status: :unauthorized unless email_verified

    # Find existing member by firebase_uid first, then fall back to email
    member = Member.find_by(firebase_uid: firebase_uid)
    member ||= Member.find_by(email: email.downcase)

    if member
      # Link firebase_uid if not already set
      member.set(firebase_uid: firebase_uid) if member.firebase_uid.blank?
    else
      # New member — create a stub record and let SignUpWorkflow complete membership
      member = Member.new(
        email:        email.downcase,
        firstname:    payload.dig('name')&.split(' ')&.first || email.split('@').first,
        lastname:     payload.dig('name')&.split(' ')&.last || '',
        firebase_uid: firebase_uid,
        status:       'inactive',
        role:         'member',
      )
      # Generate a random password so Devise is happy (member won't use it)
      member.password = SecureRandom.hex(32)
      member.save!
    end

    sign_in(:member, member)
    render json: member, adapter: :attributes
  rescue => e
    Rails.logger.error "[FirebaseAuth] Login error: #{e.message}"
    Rails.logger.error "[FirebaseAuth] Backtrace: #{e.backtrace&.first(5)&.join(' | ')}"
    Honeybadger.notify(e, context: { controller: 'FirebaseAuthController', action: 'login' })
    render json: { message: 'Authentication failed' }, status: :internal_server_error
  end

  # DELETE /api/auth/firebase_unlink/:member_id
  # Admin-only — removes firebase_uid from a member record.
  # Allows the member to recover via email/password login if Firebase is broken.
  def unlink
    raise ::Error::Forbidden.new unless is_admin? || is_board_member?

    member = Member.find(params[:member_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: params[:member_id] }) if member.nil?

    member.set(firebase_uid: nil)
    render json: {}, status: 204
  rescue Mongoid::Errors::DocumentNotFound
    render json: { message: 'Member not found' }, status: :not_found
  rescue => e
    Rails.logger.error "[FirebaseAuth] Unlink error: #{e.message}"
    Honeybadger.notify(e)
    render json: { message: 'Failed to unlink Firebase account' }, status: :internal_server_error
  end

  private

  def verify_firebase_token(id_token)
    require 'base64'
    require 'openssl'

    project_id = ENV['FIREBASE_PROJECT_ID']
    return nil if project_id.blank?

    # Split the JWT into header, payload, signature (all base64url-encoded)
    parts = id_token.split('.')
    return nil unless parts.length == 3

    header_b64, payload_b64, signature_b64 = parts

    # Decode header to find which key was used (kid)
    header = JSON.parse(base64url_decode(header_b64)) rescue nil
    return nil if header.nil?
    return nil unless header['alg'] == 'RS256'

    # Decode payload
    payload = JSON.parse(base64url_decode(payload_b64)) rescue nil
    return nil if payload.nil?

    # Validate standard claims before verifying signature
    now = Time.now.to_i
    expected_iss = "https://securetoken.google.com/#{project_id}"
    return nil if payload['exp'].to_i < now          # expired
    return nil if payload['iat'].to_i > now + 60     # issued in future (60s clock skew)
    return nil if payload['aud'] != project_id        # wrong audience
    return nil if payload['iss'] != expected_iss      # wrong issuer
    return nil if payload['sub'].blank?               # missing subject

    # Fetch Google's public certificates and verify signature
    certs = fetch_google_certs
    return nil if certs.nil?

    signing_input = "#{header_b64}.#{payload_b64}"
    signature     = base64url_decode(signature_b64)

    # Try the cert matching the kid first, then fall back to all certs
    cert_candidates = header['kid'] && certs[header['kid']] ?
      { header['kid'] => certs[header['kid']] } : certs

    cert_candidates.each do |_kid, cert_string|
      begin
        certificate = OpenSSL::X509::Certificate.new(cert_string)
        digest      = OpenSSL::Digest::SHA256.new
        verified    = certificate.public_key.verify(digest, signature, signing_input)
        return payload if verified
      rescue OpenSSL::PKey::RSAError, OpenSSL::X509::CertificateError
        next
      end
    end

    nil
  end

  def base64url_decode(str)
    # Convert base64url to standard base64 and decode
    padded = str + '=' * ((4 - str.length % 4) % 4)
    Base64.decode64(padded.tr('-_', '+/'))
  end

  def fetch_google_certs
    uri      = URI(GOOGLE_CERTS_URL)
    response = Net::HTTP.get_response(uri)
    return nil unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  rescue => e
    Rails.logger.error "[FirebaseAuth] Failed to fetch Google certs: #{e.message}"
    Honeybadger.notify(e, context: { controller: 'FirebaseAuthController', action: 'fetch_google_certs' })
    nil
  end
end
