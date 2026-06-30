class ToolCheckoutRequestsController < ApplicationController
  before_action :authenticate_member!
  before_action :ensure_active_member!, only: [:available_tools, :create]
  before_action :find_own_open_request, only: [:update, :destroy]

  def index
    requests = ToolCheckoutRequest.where(member_id: current_member.id, status: 'open')
                                  .where(:tool_id.in => Tool.pluck(:id))
                                  .order_by(created_at: :desc)
    render json: requests, each_serializer: ToolCheckoutRequestSerializer, adapter: :attributes
  end

  def available_tools
    checked_or_revoked_tool_ids = ToolCheckout.where(member_id: current_member.id).pluck(:tool_id).map(&:to_s)

    tools = Tool.where(:id.nin => checked_or_revoked_tool_ids).order_by(name: :asc).to_a
    valid_checkout_tool_ids = ToolCheckout.where(member_id: current_member.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)

    tools.each do |tool|
      unmet = (tool.prerequisite_ids || []).map(&:to_s).reject { |id| valid_checkout_tool_ids.include?(id) }
      tool.define_singleton_method(:unmet_prerequisite_ids) { unmet }
    end

    render json: tools, each_serializer: AvailableToolSerializer, adapter: :attributes
  end

  def create
    tool = Tool.find(params[:tool_id])

    if ToolCheckout.where(member_id: current_member.id, tool_id: tool.id).exists?
      render json: { error: 'Member already has a checkout record for this tool' }, status: 422 and return
    end

    if ToolCheckoutRequest.where(member_id: current_member.id, tool_id: tool.id, status: 'open').exists?
      render json: { error: 'An open checkout request already exists for this tool' }, status: 422 and return
    end

    unmet = unmet_prerequisite_ids(current_member, tool)
    if unmet.any?
      render json: { error: 'Prerequisites have not been fulfilled', unmet_prerequisite_ids: unmet }, status: 422 and return
    end

    request = ToolCheckoutRequest.new(member_id: current_member.id, tool_id: tool.id, note: request_params[:note], status: 'open')
    request.save!
    message_id = announce_request(request)
    request.update_attributes!(message_id: message_id) if message_id.present?

    render json: request, serializer: ToolCheckoutRequestSerializer, adapter: :attributes, status: :created
  end

  def update
    @request.update_attributes!(request_params)
    render json: @request, serializer: ToolCheckoutRequestSerializer, adapter: :attributes
  end

  def destroy
    replace_request_announcement(@request) if @request.message_id.present?
    @request.destroy
    render json: {}, status: 204
  end

  private

  def request_params
    params.permit(:note)
  end

  def ensure_active_member!
    render json: { error: 'Membership must be active and unexpired' }, status: 403 unless ToolCheckoutRequest.active_member?(current_member)
  end

  def find_own_open_request
    @request = ToolCheckoutRequest.find(params[:id])
    unless @request.member_id == current_member.id && @request.open? && @request.valid_tool?
      render json: { error: 'Not found' }, status: 404
    end
  end

  def unmet_prerequisite_ids(member, tool)
    valid_checkout_tool_ids = ToolCheckout.where(member_id: member.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
    (tool.prerequisite_ids || []).map(&:to_s).reject { |id| valid_checkout_tool_ids.include?(id) }
  end

  def announce_request(request)
    return unless request.tool.announce?
    message = "*#{request.member.fullname}* requested checkout on *#{request.tool.name}*.#{request.note.present? ? " Note: #{request.note}" : ''}"
    response = ::Service::SlackConnector.send_slack_message(message, announcement_channel(request.tool))
    response.try(:[], 'ts') || response.try(:[], :ts) || response.try(:ts)
  end

  def replace_request_announcement(request)
    message = "Checkout request canceled: *#{request.member.fullname}* no longer requests checkout on *#{request.tool.name}*."
    ::Service::SlackConnector.update_slack_message(message, announcement_channel(request.tool), request.message_id)
  end

  def announcement_channel(tool)
    tool.announce_channel.presence || tool.shop.try(:slack_channel)
  end
end
