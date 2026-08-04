# frozen_string_literal: true

require "digest"
require "json"
require "set"

# Builds the OpenAPI path inventory from the routes Rails actually exposes.
# Existing rswag examples deep-merge their detailed parameters, schemas and
# responses into this catalog during `rswag:specs:swaggerize`.
module OpenapiRouteCatalog
  LIFECYCLE_TAGS = %w[Frontend Webhook Orphaned].freeze
  HTTP_METHODS = %w[GET POST PUT PATCH DELETE].freeze

  # This digest deliberately makes route classification a reviewed decision.
  # The contract spec fails when an application API route is added or removed.
  AUDITED_API_OPERATION_DIGEST = "9ae9278bd6bb7bb6c487429ab3e07e3aaff0ff1a6698a4d0984438c314f6864a"

  EXCLUDED_API_OPERATIONS = Set.new([
    "GET /members/sign_in",
    "GET /members/password/new",
    "GET /members/password/edit",
    "PATCH /members/password"
  ]).freeze

  # These operations have no current React, direct-browser, webhook, scheduled,
  # callback, or documented external consumer. PATCH aliases are included: the
  # current frontend consistently uses PUT for resource updates.
  ORPHANED_OPERATIONS = Set.new([
    "GET /invoice_options/{}",
    "POST /invoices",
    "GET /admin/billing/transactions/{}",
    "PUT /admin/cards/{}",
    "GET /admin/groups",
    "GET /admin/groups/{}",
    "GET /admin/permissions",
    "PUT /admin/permissions/{}",
    "GET /admin/volunteer_events/{}"
  ]).freeze

  PUBLIC_API_OPERATIONS = Set.new([
    "POST /members/sign_in",
    "POST /members",
    "POST /send_registration",
    "POST /members/password",
    "PUT /members/password",
    "GET /invoice_options/signup",
    "GET /invoice_options",
    "GET /invoice_options/{}",
    "POST /client_error_handler",
    "GET /shops",
    "GET /tools",
    "GET /rental_spots/{}/public",
    "GET /billing/plans",
    "GET /billing/discounts",
    "GET /billing/payment_methods/new",
    "GET /config",
    "POST /auth/firebase_login",
    "DELETE /auth/firebase_unlink/{}"
  ]).freeze

  DOMAIN_TAGS = {
    "admin/analytics" => "Analytics",
    "admin/audit_logs" => "Audit Logs",
    "admin/cards" => "Cards",
    "admin/checkins" => "Check-ins",
    "admin/checkout_approvers" => "Checkout Approvers",
    "admin/earned_memberships" => "Earned Memberships",
    "admin/earned_memberships/reports" => "Reports",
    "admin/google_calendar" => "Google Calendar",
    "admin/groups" => "Households",
    "admin/invoice_options" => "Invoice Options",
    "admin/invoices" => "Invoices",
    "admin/members" => "Members",
    "admin/members/mailtrap_events" => "Mailtrap Events",
    "admin/members/totp" => "TOTP",
    "admin/permissions" => "Permissions",
    "admin/rejections" => "Access Rejections",
    "admin/rental_spots" => "Rental Spots",
    "admin/rental_types" => "Rental Types",
    "admin/rentals" => "Rentals",
    "admin/reservations" => "Reservations",
    "admin/shops" => "Shops",
    "admin/space_usage" => "Space Usage",
    "admin/system_configs" => "System Settings",
    "admin/templates" => "Templates",
    "admin/tool_checkout_requests" => "Tool Checkout Requests",
    "admin/tool_checkouts" => "Tool Checkouts",
    "admin/tools" => "Tools",
    "admin/volunteer_credits" => "Volunteer Credits",
    "admin/volunteer_events" => "Volunteer Events",
    "admin/volunteer_tasks" => "Volunteer Tasks",
    "admin/billing/receipts" => "Receipts",
    "admin/billing/subscriptions" => "Subscriptions",
    "admin/billing/transactions" => "Transactions",
    "auth/firebase_auth" => "Authentication",
    "billing/discounts" => "Discounts",
    "billing/payment_methods" => "Payment Methods",
    "billing/plans" => "Plans",
    "billing/receipts" => "Receipts",
    "billing/subscriptions" => "Subscriptions",
    "billing/transactions" => "Transactions",
    "client_config" => "Client Configuration",
    "client_error_handler" => "Client Errors",
    "devise/passwords" => "Password",
    "documents" => "Documents",
    "earned_memberships" => "Earned Memberships",
    "earned_memberships/reports" => "Reports",
    "firebase_auth" => "Authentication",
    "invoice_options" => "Invoice Options",
    "invoices" => "Invoices",
    "members" => "Members",
    "members/passwords" => "Password",
    "members/permissions" => "Permissions",
    "members/totp" => "TOTP",
    "members/totp_sessions" => "TOTP",
    "registrations" => "Authentication",
    "rental_spots" => "Rental Spots",
    "rental_types" => "Rental Types",
    "rentals" => "Rentals",
    "reservation_catalog" => "Reservations",
    "reservations" => "Reservations",
    "sessions" => "Authentication",
    "shops" => "Shops",
    "tool_checkout_requests" => "Tool Checkout Requests",
    "tool_checkouts" => "Tool Checkouts",
    "tools" => "Tools",
    "volunteer" => "Volunteer"
  }.freeze

  SPECIAL_SUMMARIES = {
    "active_members" => "Get active-member analytics",
    "add_attendee" => "Add a volunteer-event attendee",
    "add_member" => "Add a household member",
    "approve" => "Approve the resource",
    "availability" => "Check reservation availability",
    "cancel" => "Cancel the resource",
    "cancellation_impact" => "Preview subscription cancellation impact",
    "checkin_event" => "Check in to a volunteer event",
    "claim_task" => "Claim a volunteer task",
    "close" => "Close the volunteer event",
    "colors" => "List Google Calendar colors",
    "complete" => "Complete the resource",
    "complete_task" => "Complete a volunteer task",
    "credits" => "List the member's volunteer credits",
    "date_range" => "Get the available space-usage date range",
    "decline_agreement" => "Decline a rental agreement",
    "deny" => "Deny the resource",
    "events" => "List volunteer events",
    "force_cancel" => "Force-cancel the invoice",
    "for_member" => "Get the member's household",
    "invite_google_drive" => "Invite the member to Google Drive",
    "invite_slack" => "Invite the member to Slack",
    "mark_vacated" => "Mark the rental vacated",
    "member_growth" => "Get member-growth analytics",
    "my_claims" => "List the member's volunteer claims",
    "new" => "Initialize resource creation",
    "populate" => "Populate the Google template",
    "preview" => "Preview the requested change",
    "preview_create" => "Preview reservation creation",
    "preview_update" => "Preview reservation changes",
    "public_show" => "Get public rental-spot details",
    "reject" => "Reject the resource",
    "reject_pending" => "Reject the pending volunteer task",
    "release" => "Release the volunteer task",
    "remove_attendee" => "Remove a volunteer-event attendee",
    "remove_checkin" => "Remove a volunteer-event check-in",
    "remove_member" => "Remove a household member",
    "reset_cooldown" => "Reset the volunteer-task cooldown",
    "restore" => "Restore the embedded template",
    "reverse" => "Reverse the volunteer credit",
    "run_job" => "Run an administrative job",
    "send_password_reset" => "Send password-reset instructions",
    "setup" => "Start TOTP setup",
    "signup" => "List signup invoice options",
    "summary" => "Get the member's volunteer summary",
    "tasks" => "List volunteer tasks",
    "unlink" => "Unlink Firebase authentication",
    "update_flag" => "Update a system feature flag",
    "update_password" => "Update the member's password",
    "update_setting" => "Update a system setting",
    "verify" => "Verify TOTP setup",
    "volunteer_summary" => "Get volunteer analytics"
  }.freeze

  WEBHOOK_OPERATIONS = {
    "POST /ipnlistener" => {
      path: "/ipnlistener",
      controller: "paypal",
      action: "notify",
      domain_tag: "PayPal",
      operation_id: "receivePayPalIpn",
      summary: "Receive a PayPal IPN",
      description: "Receives PayPal Instant Payment Notification form data, validates it with PayPal, records recognized payments, and queues operational Slack notifications.",
      content_type: "application/x-www-form-urlencoded",
      request_schema: {
        type: :object,
        properties: {
          txn_id: { type: :string }, txn_type: { type: :string }, payment_status: { type: :string },
          mc_gross: { type: :string }, mc_currency: { type: :string }, payer_email: { type: :string },
          first_name: { type: :string }, last_name: { type: :string }, item_name: { type: :string },
          item_number: { type: :string }, recurring_payment_id: { type: :string }, mp_id: { type: :string }
        }
      },
      security: []
    },
    "POST /mailtrap_listener" => {
      path: "/mailtrap_listener",
      controller: "mailtrap",
      action: "webhooks",
      domain_tag: "Mailtrap",
      operation_id: "receiveMailtrapEvents",
      summary: "Receive Mailtrap delivery events",
      description: "Receives Mailtrap delivery, engagement, bounce, spam, rejection, suspension, and unsubscribe events. When MAILTRAP_WEBHOOK_SIGNATURE is configured, the raw JSON body must match the Mailtrap-Signature HMAC-SHA256 header.",
      content_type: "application/json",
      request_schema: {
        type: :object,
        properties: {
          events: {
            type: :array,
            items: {
              type: :object,
              properties: {
                email: { type: :string, format: :email }, event: { type: :string }, event_id: { type: :string },
                message_id: { type: :string },
                timestamp: { oneOf: [{ type: :integer }, { type: :string }] },
                response: { type: :string }
              },
              required: [:email]
            }
          }
        },
        required: [:events]
      },
      security: [{ mailtrapSignature: [] }, {}],
      responses: {
        "400" => { description: "The JSON payload could not be parsed." },
        "401" => { description: "The configured Mailtrap signature did not match." }
      }
    },
    "POST /billing/braintree_listener" => {
      path: "/billing/braintree_listener",
      controller: "billing/braintree",
      action: "webhooks",
      domain_tag: "Braintree",
      operation_id: "receiveBraintreeWebhook",
      summary: "Receive a Braintree webhook",
      description: "Receives Braintree webhook form data. The gateway validates bt_signature and bt_payload before subscription, transaction, dispute, and test notifications are processed.",
      content_type: "application/x-www-form-urlencoded",
      request_schema: {
        type: :object,
        properties: { bt_signature: { type: :string }, bt_payload: { type: :string } },
        required: [:bt_signature, :bt_payload]
      },
      security: [],
      responses: { "401" => { description: "Braintree rejected the webhook signature." } }
    }
  }.freeze

  SLACK_WEBHOOKS = {
    "/slack/commands/checkout" => ["receiveSlackCheckoutCommand", "Receive the Slack checkout command", "Validates a Slack-signed slash command and queues tool-checkout processing, returning an ephemeral acknowledgement within Slack's response window."],
    "/slack/commands/reserve" => ["receiveSlackReserveCommand", "Receive the Slack reservation command", "Validates a Slack-signed slash command, checks the linked member and shop, and opens the reservation modal."],
    "/slack/commands/volunteer" => ["receiveSlackVolunteerCommand", "Receive the Slack volunteer command", "Validates a Slack-signed slash command and queues volunteer command processing, returning an ephemeral acknowledgement."],
    "/slack/interactions" => ["receiveSlackInteraction", "Receive a Slack interaction", "Validates a Slack-signed interaction payload and processes reservation modal submissions."]
  }.freeze

  module_function

  def paths
    operations.each_with_object({}) do |operation, result|
      result[operation[:path]] ||= {}
      result[operation[:path]][operation[:verb].downcase.to_sym] = operation_payload(operation)
    end
  end

  def operations
    @operations ||= begin
      api_operations = Rails.application.routes.routes.flat_map { |route| Array(operation_from_route(route)) }
      webhook_operations = webhook_metadata
      (api_operations + webhook_operations).uniq { |operation| [operation[:verb], operation[:path]] }
    end
  end

  def api_operation_keys
    operations.reject { |operation| operation[:lifecycle] == "Webhook" }
      .map { |operation| canonical_key(operation[:verb], operation[:path]) }
      .sort
  end

  def api_operation_digest
    Digest::SHA256.hexdigest(api_operation_keys.join("\n"))
  end

  def canonical_key(verb, path)
    normalized_path = path.to_s.gsub(/\{[^}]+\}/, "{}")
    "#{verb.to_s.upcase} #{normalized_path}"
  end

  def lifecycle_for(verb, path)
    key = canonical_key(verb, path)
    return "Orphaned" if verb.to_s.upcase == "PATCH" || ORPHANED_OPERATIONS.include?(key)

    "Frontend"
  end

  def legacy_document
    @legacy_document ||= begin
      file = Rails.root.join("swagger/v1/swagger.json")
      file.exist? ? JSON.parse(file.read) : { "paths" => {} }
    rescue JSON::ParserError
      { "paths" => {} }
    end
  end

  def legacy_operation(verb, path)
    key = canonical_key(verb, path)
    legacy_document.fetch("paths", {}).each do |legacy_path, path_item|
      operation = path_item[verb.to_s.downcase]
      return [legacy_path, operation] if operation && canonical_key(verb, legacy_path) == key
    end
    [path, nil]
  end

  def operation_from_route(route)
    raw_path = route.path.spec.to_s.sub("(.:format)", "")
    return unless raw_path.start_with?("/api/")

    controller = route.defaults[:controller].to_s
    action = route.defaults[:action].to_s
    return if controller.blank? || action.blank?

    verbs = route.verb.to_s.scan(/[A-Z]+/) & HTTP_METHODS
    verbs.filter_map do |verb|
      openapi_path = raw_path.delete_prefix("/api").gsub(/:([a-zA-Z_]+)/, '{\1}')
      canonical = canonical_key(verb, openapi_path)
      next if EXCLUDED_API_OPERATIONS.include?(canonical)

      legacy_path, legacy = legacy_operation(verb, openapi_path)
      lifecycle = lifecycle_for(verb, legacy_path)
      {
        verb: verb,
        path: legacy_path,
        controller: controller,
        action: action,
        lifecycle: lifecycle,
        domain_tag: legacy&.fetch("tags", nil)&.first || domain_tag(controller),
        operation_id: legacy&.fetch("operationId", nil) || generated_operation_id(verb, controller, action),
        summary: summary_for(controller, action),
        description: description_for(controller, action, lifecycle, canonical),
        security: security_for(verb, canonical),
        response_content_type: response_content_type(route)
      }
    end
  end

  def webhook_metadata
    base = WEBHOOK_OPERATIONS.map do |key, metadata|
      verb, = key.split(" ", 2)
      metadata.merge(verb: verb, lifecycle: "Webhook", response_content_type: "application/json")
    end

    slack = SLACK_WEBHOOKS.map do |path, (operation_id, summary, description)|
      {
        verb: "POST",
        path: path,
        controller: path == "/slack/interactions" ? "slack/interactions" : "slack/commands",
        action: path.split("/").last,
        lifecycle: "Webhook",
        domain_tag: "Slack",
        operation_id: operation_id,
        summary: summary,
        description: description,
        content_type: "application/x-www-form-urlencoded",
        request_schema: slack_request_schema(path),
        security: [{ slackSignature: [] }],
        responses: { "403" => { description: "The Slack signature or request timestamp was rejected." } },
        response_content_type: "application/json"
      }
    end
    base + slack
  end

  def operation_payload(operation)
    payload = {
      tags: [operation[:domain_tag], operation[:lifecycle]],
      operationId: operation[:operation_id],
      summary: operation[:summary],
      description: operation[:description],
      security: operation[:security],
      parameters: path_parameters(operation[:path]),
      responses: default_responses(operation).merge(operation.fetch(:responses, {}))
    }
    payload[:servers] = [{ url: "/", description: "Application root" }] if operation[:lifecycle] == "Webhook"

    if operation[:request_schema]
      payload[:requestBody] = {
        required: true,
        content: { operation[:content_type] => { schema: operation[:request_schema] } }
      }
    elsif %w[POST PUT PATCH].include?(operation[:verb])
      payload[:requestBody] = {
        required: false,
        content: { "application/json" => { schema: { type: :object, additionalProperties: true } } }
      }
    end
    payload
  end

  def default_responses(operation)
    content_type = operation[:response_content_type]
    response = { description: "Request completed successfully." }
    response[:content] = { content_type => {} } if content_type
    responses = { "200" => response }
    responses["401"] = { description: "Authentication or signature verification failed." } unless operation[:security].empty?
    responses
  end

  def path_parameters(path)
    path.scan(/\{([^}]+)\}/).flatten.map do |name|
      { name: name.to_sym, in: :path, required: true, schema: { type: :string } }
    end
  end

  def response_content_type(route)
    route.defaults[:format].to_s == "html" ? "text/html" : "application/json"
  end

  def security_for(verb, canonical)
    return [] if PUBLIC_API_OPERATIONS.include?(canonical) && verb == "GET"
    return [{ csrfToken: [] }] if PUBLIC_API_OPERATIONS.include?(canonical)
    return [{ cookieAuth: [] }] if verb == "GET"

    [{ cookieAuth: [], csrfToken: [] }]
  end

  def domain_tag(controller)
    DOMAIN_TAGS.fetch(controller) { controller.split("/").last.tr("_", " ").titleize }
  end

  def generated_operation_id(verb, controller, action)
    "#{verb.downcase}#{controller.split('/').map(&:camelize).join}#{action.camelize}"
  end

  def summary_for(controller, action)
    return SPECIAL_SUMMARIES[action] if SPECIAL_SUMMARIES.key?(action)

    resource = domain_tag(controller)
    case action
    when "index" then "List #{resource.downcase}"
    when "show" then "Get #{resource.singularize.downcase}"
    when "create" then "Create #{resource.singularize.downcase}"
    when "update" then "Update #{resource.singularize.downcase}"
    when "destroy" then "Delete #{resource.singularize.downcase}"
    else action.tr("_", " ").capitalize
    end
  end

  def description_for(controller, action, lifecycle, canonical)
    audience = if canonical.start_with?("GET /admin/", "POST /admin/", "PUT /admin/", "PATCH /admin/", "DELETE /admin/")
                 "Available to authorized administrative portal users; controller policy may further limit resource managers, board members, or checkout approvers."
               elsif PUBLIC_API_OPERATIONS.include?(canonical)
                 "This operation does not require an authenticated member session."
               else
                 "Requires an authenticated member session and is limited by the controller's ownership or capability checks."
               end
    consumer = if lifecycle == "Orphaned"
                 "No current frontend, direct-browser, callback, scheduled, or documented external caller was found; retain only while its ownership is confirmed."
               else
                 "Used by the current makerspace-react-2026 member portal."
               end
    "#{summary_for(controller, action)}. #{audience} #{consumer}"
  end

  def slack_request_schema(path)
    return {
      type: :object,
      properties: { payload: { type: :string, description: "JSON-encoded Slack interaction payload." } },
      required: [:payload]
    } if path == "/slack/interactions"

    {
      type: :object,
      properties: {
        command: { type: :string }, text: { type: :string }, channel_name: { type: :string },
        user_id: { type: :string }, user_name: { type: :string }, trigger_id: { type: :string }
      },
      required: [:command, :user_id]
    }
  end
end
