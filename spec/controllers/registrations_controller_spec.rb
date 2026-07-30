require 'rails_helper'

RSpec.describe RegistrationsController, type: :controller do
  set_devise_mapping

  around do |example|
    original_token = ENV["REGISTRATION_EMAIL_TOKEN"]
    ENV["REGISTRATION_EMAIL_TOKEN"] = "registration-email-secret"
    example.run
  ensure
    ENV["REGISTRATION_EMAIL_TOKEN"] = original_token
  end

  email = 'new_emails@email.com'
  let(:registration_email_hash) {
    OpenSSL::HMAC.hexdigest("SHA256", "registration-email-secret", "foo@foo.com").first(16)
  }
  let(:token) {SecureRandom.urlsafe_base64(nil, false)}
  let(:encrypted_token) {BCrypt::Password.create(token)}
  let(:token_model) { create(:registration_token, email: email)}

  let(:valid_attributes) {
    {
      firstname: 'New',
      lastname: 'Member',
      email: email,
      password: 'password',
      password_confirmation: 'password',
      token_id: token_model.id,
      token: token,
      signature: "data:image/png;base64," + Base64.encode64(File.new("#{Rails.root}/spec/support/makerspace.png").read)
    }
  }

  let(:invalid_attributes) {
    skip("Add a hash of attributes invalid for your model")
  }

  before(:all) do
    clear_email
  end

  before(:each) do
    token_model.update(token: encrypted_token)
  end

  describe "POST #create" do
    context "with valid params" do
      it "creates a new Member" do
        expect {
          post :create, params: valid_attributes, format: :json
        }.to change(Member, :count).by(1)
      end

      it "assigns a newly created member as @member" do
        post :create, params: valid_attributes, format: :json
        expect(Member.last).to be_a(Member)
        expect(Member.last).to be_persisted
      end

      it "renders json of the created member" do
        post :create, params: valid_attributes, format: :json

        parsed_response = JSON.parse(response.body)
        expect(response).to have_http_status(200)
        expect(response.media_type).to eq "application/json"
        expect(parsed_response['id']).to eq(Member.last.id.as_json)
      end

      it "sends registration notification to us" do
        allow(MemberMailer).to receive_message_chain(:member_registered, :deliver_later)
        expect(MemberMailer).to receive_message_chain(:member_registered, :deliver_later)
        post :create, params: valid_attributes, format: :json
      end

      it "continues signup and reports a Slack invite failure without returning 500" do
        slack_error = StandardError.new("not_authed")
        allow(MemberSubscriber).to receive(:invite_to_slack).and_raise(slack_error)
        allow(::Service::SlackConnector).to receive(:send_slack_message).and_return(true)
        allow(Honeybadger).to receive(:notify)

        expect do
          post :create, params: valid_attributes, format: :json
        end.to change(Member, :count).by(1)

        expect(response).to have_http_status(200)

        audit_entry = AuditLog.where(event_type: "slack_invite_failed").last
        expect(audit_entry).to be_present
        expect(audit_entry.resource_id).to eq(Member.last.id)
        expect(audit_entry.slack_channel).to eq(::Service::SlackConnector.logs_channel)
        expect(audit_entry.slack_posted).to be(true)
        expect(audit_entry.field_changes.dig("slack_invite", 1)).to include("not_authed")

        expect(::Service::SlackConnector).to have_received(:send_slack_message).with(
          /Slack invite failed.*not_authed/i,
          ::Service::SlackConnector.logs_channel
        )
        expect(Honeybadger).to have_received(:notify).with(
          slack_error,
          context: hash_including(
            event_type: "slack_invite_failed",
            member_email: email
          )
        )
      end

      it "continues signup when posting the invite failure to Slack also fails" do
        invite_error = StandardError.new("not_authed")
        log_error = StandardError.new("interface log not_authed")
        allow(MemberSubscriber).to receive(:invite_to_slack).and_raise(invite_error)
        allow(::Service::SlackConnector).to receive(:send_slack_message).and_raise(log_error)
        allow(Honeybadger).to receive(:notify)

        post :create, params: valid_attributes, format: :json

        expect(response).to have_http_status(200)
        audit_entry = AuditLog.where(event_type: "slack_invite_failed").last
        expect(audit_entry).to be_present
        expect(audit_entry.slack_channel).to eq(::Service::SlackConnector.logs_channel)
        expect(audit_entry.slack_posted).to be(false)
        expect(Honeybadger).to have_received(:notify).with(
          invite_error,
          context: hash_including(event_type: "slack_invite_failed")
        )
        expect(Honeybadger).to have_received(:notify).with(
          log_error,
          context: hash_including(slack_channel: ::Service::SlackConnector.logs_channel)
        )
      end
    end

    # context "with invalid params" do
    #   it "assigns a newly created but unsaved registration as @registration" do
    #     post :create, params: {registration: invalid_attributes}, session: valid_session
    #     expect(assigns(:registration)).to be_a_new(Registration)
    #   end
    #
    #   it "re-renders the 'new' template" do
    #     post :create, params: {registration: invalid_attributes}, session: valid_session
    #     expect(response).to render_template("new")
    #   end
    # end
  end

  describe "GET #new" do
    it "throws errors if email missing" do
      get :new, params: { token: registration_email_hash }, format: :json
      expect(response).to have_http_status(422)
    end

    it "rejects requests without the registration email token" do
      expect(MemberMailer).not_to receive(:welcome_email)

      get :new, params: { email: "foo@foo.com" }, format: :json

      expect(response).to have_http_status(401)
    end

    it "rejects requests with an invalid registration email token" do
      expect(MemberMailer).not_to receive(:welcome_email)

      get :new, params: { email: "foo@foo.com", token: "incorrect" }, format: :json

      expect(response).to have_http_status(401)
    end

    it "it notifies admin and raises error if email already exists" do
      create(:member, email: "foo@foo.com")
      get :new, params: {email: "foo@foo.com", token: registration_email_hash}, format: :json
      expect(response).to have_http_status(409)
    end

    it "sends welcome email to new member" do
      allow(MemberMailer).to receive_message_chain(:welcome_email, :deliver_later)
      expect(MemberMailer).to receive_message_chain(:welcome_email, :deliver_later)
      expect(MemberMailer).to receive(:welcome_email).with("foo@foo.com")
      get :new, params: {email: "foo@foo.com", token: registration_email_hash}, format: :json
    end

    it "allows requests without a token when the server token is unset or empty" do
      allow(MemberMailer).to receive_message_chain(:welcome_email, :deliver_later)

      [nil, ""].each do |server_token|
        ENV["REGISTRATION_EMAIL_TOKEN"] = server_token
        get :new, params: { email: "unprotected@example.com" }, format: :json
        expect(response).to have_http_status(204)
      end
    end
  end
end
