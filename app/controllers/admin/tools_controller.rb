class Admin::ToolsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorize_index, only: [:index]
  before_action :find_tool, only: [:update, :destroy]
  before_action :authorize_create, only: [:create]
  before_action :authorize_manage, only: [:update, :destroy]
  before_action :prevent_move_with_active_reservations, only: [:update]

  def index
    tools = params[:shop_id] ? Tool.where(shop_id: params[:shop_id]) : Tool.all
    unless is_admin? || is_board_member?
      managed_ids = Tool.where(:shop_id.in => managed_shop_ids).pluck(:id).map(&:to_s)
      ordinary_ids = current_member.valid_for_checkout_request? ?
        CheckoutApprover.allowed_tool_ids_for_member(current_member.id) : []
      visible_ids = (managed_ids + ordinary_ids).uniq
      tools = tools.where(:id.in => visible_ids)
      tools = tools.any_of(
        { :shop_id.in => managed_shop_ids },
        { :id.in => ordinary_ids, :disabled.ne => true }
      )
    end
    tools = tools.order_by(name: :asc)
    scope_key = if is_admin? || is_board_member?
      "global"
    else
      "member=#{current_member.id}/shops=#{managed_shop_ids.sort.join(',')}"
    end
    payload = CachedPayload.collection(
      "tools/admin/#{scope_key}/shop=#{params[:shop_id]}",
      tools,
      serializer: AdminToolSerializer,
      dependencies: ["tools", "shops", "checkout_approvers", "members"],
      scope: current_member,
      management_shop_ids: managed_shop_ids,
      global_management: is_admin? || is_board_member?
    )
    response.set_header("total-items", payload.length)
    render json: payload.to_json
  end

  def create
    tool = Tool.new(tool_params)
    tool.save!
    GoogleResourceSyncJob.perform_later("Tool", tool.id.to_s)

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
    if @tool.resource_email.blank? || @tool.previous_changes.key?("name") || @tool.previous_changes.key?("reservable")
      GoogleResourceSyncJob.perform_later("Tool", @tool.id.to_s)
    end

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
    if current_or_future_blocking_reservations.exists?
      raise ::Error::Conflict.new("Cancel future reservations before deleting this tool")
    end
    before = @tool.attributes.dup
    google_resource_id = @tool.google_resource_id
    label_source_id = @tool.id.to_s
    @tool.destroy
    GoogleResourceDeleteJob.perform_later(google_resource_id, label_source_id)
    CheckoutApprover.where(:tool_ids.in => [before["_id"].to_s]).each do |approver|
      approver.pull(tool_ids: before["_id"].to_s)
      approver.destroy if approver.shop_ids.blank? && approver.tool_ids.blank?
    end

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

  def tool_params
    params.permit(:name, :description, :shop_id, :disabled, :announce,
      :announce_channel, :users_channel, :reservable,
      :max_concurrent_reservations, :reservation_horizon_days,
      :max_reservation_duration_hours, :reservation_requires_approval,
      prerequisite_ids: [], reservation_prerequisite_tool_ids: [])
  end

  def find_tool
    @tool = Tool.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Tool, { id: params[:id] }) if @tool.nil?
  end

  def authorize_index
    unless is_admin? || is_board_member? || managed_shop_ids.present? || is_valid_checkout_approver?
      raise ::Error::Forbidden.new("User is not privileged or a checkout approver")
    end
  end

  def authorize_create
    shop = Shop.find(tool_params[:shop_id])
    raise ::Error::Forbidden.new("User cannot manage this shop") unless can_manage_shop?(shop)
  end

  def authorize_manage
    raise ::Error::Forbidden.new("User cannot manage this shop") unless can_manage_shop?(@tool.shop_id)

    target_shop_id = tool_params[:shop_id].presence
    if target_shop_id && !can_manage_shop?(target_shop_id)
      raise ::Error::Forbidden.new("User cannot move this tool to that shop")
    end
  end

  def prevent_move_with_active_reservations
    return unless tool_params.key?(:shop_id)
    return if tool_params[:shop_id].to_s == @tool.shop_id.to_s
    return unless current_or_future_blocking_reservations.exists?

    raise ::Error::Conflict.new(
      "Cancel current and future reservations before moving this tool"
    )
  end

  def current_or_future_blocking_reservations
    Reservation.blocking.where(
      tool_ids: @tool.id.to_s,
      :end_at.gt => Time.current
    )
  end
end
