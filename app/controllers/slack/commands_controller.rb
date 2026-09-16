# Handles inbound Slack slash commands.
#
# Slack sends a POST to /slack/commands when a slash command is used.
# The payload includes: command, text, channel_name, user_id, user_name
#
# Response must be returned within 3 seconds (Slack timeout).
# All processing is deferred to jobs to avoid the timeout.
#
# Commands:
#   /checkout @member tool-name   — tool checkout, current shop channel (SlackCheckoutJob)
#   /checkout request [tool-name] — member self-service checkout request (SlackCheckoutRequestJob)
#   /checkout active [all]        — list the caller's active checkouts (SlackCheckoutActiveJob)
#   /reserve                       — reserve a shop/tool in the current shop channel
#   /volunteer <subcommand>       — volunteer credits/tasks (SlackVolunteerJob)
#
class Slack::CommandsController < ApplicationController
  include Service::SlackConnector
  skip_before_action :verify_authenticity_token
  before_action :verify_slack_signature

  def checkout
    text = params[:text].to_s.strip
    command = text.split(/\s+/, 2).first&.downcase

    if command == 'request'
      return handle_checkout_request(text)
    end

    if command == 'active'
      SlackCheckoutActiveJob.perform_later(params.to_unsafe_h.stringify_keys)
      render json: { response_type: 'ephemeral', text: 'Looking up your active checkouts...' }
      return
    end

    parts = text.split(/\s+/, 2)
    if parts.length < 2
      render json: {
        response_type: 'ephemeral',
        text: 'Usage: `/checkout @member tool-name`, `/checkout email@example.com tool-name`, `/checkout request [tool-name]`, or `/checkout active [all]`'
      } and return
    end

    unless checkout_shop_channel?
      return render json: { response_type: 'ephemeral', text: checkout_shop_channel_instruction }
    end

    unless find_slack_member
      return render json: {
        response_type: "ephemeral",
        text: "Link your Slack account to a Member Portal account before using /checkout."
      }
    end

    member_token = parts[0]
    tool_name    = parts[1]

    SlackCheckoutJob.perform_later(params.to_unsafe_h.stringify_keys)

    render json: {
      response_type: 'ephemeral',
      text: "Processing checkout of *#{tool_name}* for *#{member_token}*..."
    }
  end

  def volunteer
    SlackVolunteerJob.perform_later(params.to_unsafe_h.stringify_keys)

    render json: {
      response_type: 'ephemeral',
      text: 'Processing your volunteer command...'
    }
  end

  def reserve
    slack_request = nil
    channel_name=Service::SlackChannelCache.normalize_name( params[:channel_name] )
    shop = Shop.find_by(slack_channel: channel_name ) || Shop.find_by(slack_channel: params[:channel_name])
    unless shop
      render json: {
        response_type: "ephemeral",
        text: "No shop is configured for #{channel_name}."
      } and return
    end

    slack_user = SlackUser.find_by(slack_id: params[:user_id])
    member = slack_user && Member.find_by(id: slack_user.member_id)
    unless member&.active_unexpired?
      render json: {
        response_type: "ephemeral",
        text: "Link an active Member Portal account before using /reserve."
      } and return
    end

    view = SlackReservationModal.build(shop, member)
    slack_request = { method: "views.open", arguments: { trigger_id: params[:trigger_id], view: view } }
    Service::SlackConnector.open_modal(params[:trigger_id], view)
    render json: { response_type: "ephemeral", text: "Opening reservation form…" }
  rescue ::Error::CustomError => error
    Rails.logger.warn(
      "[SlackReservationRejected] action=open_modal slack_user_id=#{params[:user_id]} reason=#{error.message}"
    )
    render json: { response_type: "ephemeral", text: error.message }
  rescue => error
    Rails.logger.error(
      "[SlackReservationError] action=open_modal slack_user_id=#{params[:user_id]} " \
      "error=#{Service::SlackConnector.format_api_error(error, request: slack_request)}"
    )
    Honeybadger.notify(error) if defined?(Honeybadger)
    render json: {
      response_type: "ephemeral",
      text: "The reservation form could not be opened. Please try again or use the Member Portal."
    }
  end

  private

  # /checkout request [tool-name] -- member self-service, distinct from the
  # admin/approver-driven `/checkout @member tool-name` above. With no tool
  # name it opens the eligible-tool modal; a name queues the request job.
  def handle_checkout_request(text)
    tool_name = text.split(/\s+/, 2)[1].to_s.strip.presence
    member = find_slack_member
    raise ::Error::UnprocessableEntity.new("Link your Slack account to a Member Portal account first") unless member

    unless tool_name
      shop = current_checkout_shop

      unless shop && checkout_shop_channel?
        render json: {
          response_type: "ephemeral",
          text: open_request_list(member)
        }
        return
      end

      view = SlackCheckoutRequestModal.build(shop, member)
      Service::SlackConnector.open_modal(params[:trigger_id], view)
      message = "Opening checkout request form…"
      if active_checkout_in_shop?(member, shop)
        message += "\nKnow these tools well? Volunteering as a checkout approver can help everybody's checkouts move faster."
      end
      render json: { response_type: "ephemeral", text: message }
      return
    end


    unless current_checkout_shop && checkout_shop_channel?
      return render json: { response_type: 'ephemeral', text: checkout_shop_channel_instruction }
    end

    SlackCheckoutRequestJob.perform_later(params.to_unsafe_h.stringify_keys.merge('tool_name' => tool_name))

    render json: {
      response_type: 'ephemeral',
      text: "Processing your request for *#{tool_name}*..."
    }
  rescue ::Error::CustomError => error
    render json: { response_type: "ephemeral", text: error.message }
  rescue => error
    Service::ErrorReporter.notify(error, context: { phase: "open checkout request modal", slack_user_id: params[:user_id] })
    render json: { response_type: "ephemeral", text: "The checkout request form could not be opened. Please try again or use the Member Portal." }
  end

  def find_slack_member
    slack_user = SlackUser.find_by(slack_id: params[:user_id])
    member = slack_user && Member.find_by(id: slack_user.member_id)
    return member if member

    return nil unless Service::SlackUserSync.sync_single(params[:user_id])
    slack_user = SlackUser.find_by(slack_id: params[:user_id])
    slack_user && Member.find_by(id: slack_user.member_id)
  end

  def current_checkout_shop
    channel_name = Service::SlackChannelCache.normalize_name(params[:channel_name])
    Shop.find_by(slack_channel: channel_name) || Shop.find_by(slack_channel: params[:channel_name])
  end

  def checkout_shop_channel?
    Service::ShopSlackChannels.associated?(
      channel_name: params[:channel_name],
      channel_id: params[:channel_id]
    )
  end

  def checkout_shop_channel_instruction
    channels = Service::ShopSlackChannels.resolved
    introduction = "Checkout approvals and new requests must start in the appropriate shop channel."
    return "#{introduction} Please join a public shop channel and run `/checkout` there." if channels.empty?

    channel_list = channels.map { |channel| "• <##{channel.id}> — *#{channel.shop.name}*" }.join("\n")
    "#{introduction}\n\nAvailable shop channels:\n#{channel_list}\n\nJoin the appropriate channel, then run `/checkout` there."
  rescue => error
    Rails.logger.warn("[SlackCheckout] shop channel instructions unavailable error=#{error.class}: #{error.message}")
    "Checkout approvals and new requests must start in an appropriate public shop channel."
  end

  def open_request_list(member)
    requests = ToolCheckoutRequest.where(member_id: member.id, status: "open").to_a
      .sort_by { |request| [request.tool&.shop&.name.to_s.downcase, request.tool&.name.to_s.downcase] }
    return "You have no open checkout requests." if requests.empty?

    lines = requests.map { |request| "• *#{request.tool&.name}* — #{request.tool&.shop&.name || 'Unknown shop'}" }
    "*Your open checkout requests:*\n#{lines.join("\n")}"
  end

  def active_checkout_in_shop?(member, shop)
    tool_ids = Tool.where(shop_id: shop.id).pluck(:id)
    ToolCheckout.where(member_id: member.id, :tool_id.in => tool_ids, revoked_at: nil).exists?
  end

  # Verify the request actually came from Slack using signing secret
  def verify_slack_signature
    slack_signing_secret = ENV['SLACK_SIGNING_SECRET']
    if slack_signing_secret.blank?
      return if Rails.env.development?

      render json: { error: 'Slack signing secret is not configured' }, status: 403
      return
    end

    timestamp = request.headers['X-Slack-Request-Timestamp']
    signature = request.headers['X-Slack-Signature']
    body      = request.raw_post

    # Reject if timestamp is >5 minutes old (replay attack prevention)
    if (Time.now.to_i - timestamp.to_i).abs > 300
      render json: { error: 'Request too old' }, status: 403 and return
    end

    sig_basestring = "v0:#{timestamp}:#{body}"
    my_signature   = "v0=#{OpenSSL::HMAC.hexdigest('SHA256', slack_signing_secret, sig_basestring)}"

    unless ActiveSupport::SecurityUtils.secure_compare(my_signature, signature.to_s)
      render json: { error: 'Invalid signature' }, status: 403
    end
  end
end
