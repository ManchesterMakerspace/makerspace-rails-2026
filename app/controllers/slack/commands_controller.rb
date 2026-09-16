# Handles inbound Slack slash commands.
#
# Slack sends a POST to /slack/commands when a slash command is used.
# The payload includes: command, text, channel_name, user_id, user_name
#
# Response must be returned within 3 seconds (Slack timeout).
# Modal-opening commands are handled synchronously because Slack trigger IDs
# expire quickly; longer-running legacy workflows are deferred to jobs.
#
# Commands:
#   /checkout @member tool-name   — tool checkout, current shop channel (SlackCheckoutJob)
#   /checkout request             — member self-service request modal, current shop channel
#   /reserve                       — reserve a shop/tool in the current shop channel
#   /volunteer <subcommand>       — volunteer credits/tasks (SlackVolunteerJob)
#
class Slack::CommandsController < ApplicationController
  include Service::SlackConnector
  skip_before_action :verify_authenticity_token
  before_action :verify_slack_signature

  def checkout
    text = params[:text].to_s.strip
    shop = current_slack_shop
    unless shop
      return render json: { response_type: "ephemeral", text: "No shop is configured for this channel." }
    end

    slack_user = SlackUser.find_by(slack_id: params[:user_id])
    member = slack_user && Member.find_by(id: slack_user.member_id)
    unless member
      synced_member = Service::SlackUserSync.sync_single(params[:user_id])
      if synced_member
        slack_user = SlackUser.find_by(slack_id: params[:user_id])
        member = slack_user && Member.find_by(id: slack_user.member_id)
      end
    end
    unless member
      return render json: { response_type: "ephemeral", text: "Link your Slack account to a Member Portal account before using /checkout." }
    end

    unless Service::ShopSlackChannels.associated?(
      channel_name: params[:channel_name],
      channel_id: params[:channel_id]
    )
      return render json: {
        response_type: 'ephemeral',
        text: checkout_shop_channel_instruction
      }
    end

    if text.split(/\s+/, 2).first&.downcase == 'request'
      return open_checkout_request_modal(shop, member)
    end

    parts = text.split(/\s+/, 2)
    if parts.length < 2
      return open_checkout_request_modal(shop, member) unless checkout_approver_for_shop?(member, shop)

      render json: {
        response_type: 'ephemeral',
        text: 'Usage: `/checkout @member tool-name`, `/checkout email@example.com tool-name`, or `/checkout request`'
      } and return
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

  def checkout_shop_channel_instruction
    channels = Service::ShopSlackChannels.resolved
    introduction = "Checkout requests must start in the appropriate shop channel."

    if channels.empty?
      return "#{introduction} Please join the public Slack channel for the shop whose tools you use, then run `/checkout` there."
    end

    channel_list = channels.map do |channel|
      "• <##{channel.id}> — *#{channel.shop.name}*"
    end.join("\n")

    "#{introduction}\n\nAvailable shop channels:\n#{channel_list}\n\n" \
      "Join the appropriate channel, then run `/checkout` there."
  rescue => error
    Rails.logger.warn(
      "[SlackCheckout] shop channel instructions unavailable error=#{error.class}: #{error.message}"
    )
    "Checkout requests must start in the appropriate shop channel. " \
      "Please join the public Slack channel for the shop whose tools you use, then run `/checkout` there."
  end

  # /checkout request [tool-name] -- member self-service, distinct from the
  # admin/approver-driven `/checkout @member tool-name` above. No arguments
  # lists eligible tools; a tool name requests a new checkout, or re-sends
  # the notes DM if the member already has an active checkout on it.
  def handle_checkout_request(text)
    tool_name = text.split(/\s+/, 2)[1].to_s.strip.presence

  def checkout_approver_for_shop?(member, shop)
    return true if %w[admin board_member].include?(member.role) || member.manages_shop?(shop)
    approver = member.valid_for_checkout_request? && CheckoutApprover.find_by(member_id: member.id)
    approver && (approver.can_approve_for_shop?(shop.id) ||
      Tool.where(shop_id: shop.id, :id.in => Array(approver.tool_ids)).exists?)
  end

  def open_checkout_request_modal(shop, member)
    view = SlackCheckoutRequestModal.build(shop, member)
    Service::SlackConnector.open_modal(params[:trigger_id], view)
    render json: { response_type: "ephemeral", text: "Opening checkout request form…" }
  rescue ::Error::CustomError => error
    render json: { response_type: "ephemeral", text: error.message }
  rescue => error
    Service::ErrorReporter.notify(error, context: { phase: "open checkout request modal", slack_user_id: params[:user_id] })
    render json: { response_type: "ephemeral", text: "The checkout request form could not be opened. Please try again or use the Member Portal." }
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
