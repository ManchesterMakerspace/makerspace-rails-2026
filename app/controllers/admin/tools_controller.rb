class Admin::ToolsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorized?
  before_action :find_tool, only: [:update, :destroy]

  def index
    tools = params[:shop_id] ? Tool.where(shop_id: params[:shop_id]) : Tool.all
    tools = tools.where(:shop_id.in => current_approver_shop_ids) unless is_privileged?
    tools = tools.order_by(name: :asc)
    render json: tools, each_serializer: ToolSerializer, adapter: :attributes
  end

  def create
    tool = Tool.new(tool_params)
    tool.save!

    ::Service::AuditLogger.log(
      log_type:       'portal',
      event_type:     'tool_created',
      resource_type:  'Tool',
      resource_id:    tool.id,
      actor:          current_member,
      after_snapshot: tool.attributes
    )

    render json: tool, serializer: ToolSerializer, adapter: :attributes
  end

  def update
    before = @tool.attributes.dup
    @tool.update_attributes!(tool_params)

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'tool_updated',
      resource_type:   'Tool',
      resource_id:     @tool.id,
      actor:           current_member,
      field_changes:   @tool.previous_changes,
      before_snapshot: before,
      after_snapshot:  @tool.attributes
    )

    render json: @tool, serializer: ToolSerializer, adapter: :attributes
  end

  def destroy
    before = @tool.attributes.dup
    @tool.destroy

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'tool_deleted',
      resource_type:   'Tool',
      resource_id:     before['_id'],
      actor:           current_member,
      before_snapshot: before,
      after_snapshot:  {}
    )

    render json: {}, status: 204
  end

  private

  def authorized?
    return if is_privileged?
    return if action_name == 'index' && active_checkout_approver?

    raise ::Error::Forbidden.new
  end

  def active_checkout_approver?
    ToolCheckoutRequest.active_member?(current_member) && CheckoutApprover.exists?(member_id: current_member.id)
  end

  def current_approver_shop_ids
    CheckoutApprover.find_by(member_id: current_member.id).try(:shop_ids) || []
  end

  def tool_params
    params.permit(:name, :description, :shop_id, :disabled, :announce, :announce_channel, prerequisite_ids: [])
  end

  def find_tool
    @tool = Tool.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Tool, { id: params[:id] }) if @tool.nil?
  end
end
