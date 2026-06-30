class Admin::ToolCheckoutsController < ApplicationController
  include Service::SlackConnector
  before_action :authenticate_member!
  before_action :authorized?
  before_action :find_checkout, only: [:update, :destroy]
  before_action :authorize_approver, only: [:create, :destroy]

  def index
    checkouts = ToolCheckout.all

    unless is_privileged?
      checkouts = checkouts.where(:tool_id.in => approver_visible_tool_ids)
    end

    # Filter by member, tool, shop, active status
    checkouts = checkouts.where(member_id: params[:member_id]) if params[:member_id].present?
    checkouts = checkouts.where(tool_id: params[:tool_id]) if params[:tool_id].present?
    checkouts = checkouts.where(revoked_at: nil) if params[:active] == "true"
    checkouts = checkouts.where(:revoked_at.ne => nil) if params[:active] == "false"

    # Filter by shop — join through tool
    if params[:shop_id].present?
      tool_ids = Tool.where(shop_id: params[:shop_id]).pluck(:id)
      checkouts = checkouts.where(:tool_id.in => tool_ids)
    end

    checkouts = checkouts.order_by(checked_out_at: :desc)
    render json: checkouts, each_serializer: ToolCheckoutSerializer, adapter: :attributes
  end

  def create
    member = Member.find(checkout_params[:member_id])
    tool   = Tool.find(checkout_params[:tool_id])

    unmet = unmet_prerequisites(member, tool)
    if unmet.present? && !is_privileged?
      render json: { error: 'Prerequisites are not met', unmet_prerequisites: unmet.map(&:name) }, status: 422 and return
    end

    # Prevent duplicate active checkout
    existing = ToolCheckout.find_by(member_id: member.id, tool_id: tool.id, revoked_at: nil)
    if existing
      render json: { error: "Member is already checked out on this tool" }, status: 422 and return
    end

    checkout = ToolCheckout.new(
      member_id:      member.id,
      tool_id:        tool.id,
      approved_by_id: current_member.id,
      signed_off_via: "portal",
      checked_out_at: Time.now
    )
    checkout.save!
    checkout.send_checkout_slack_notification

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'tool_checkout_created',
      resource_type:  'ToolCheckout',
      resource_id:    checkout.id,
      actor:          current_member,
      subject:        member,
      after_snapshot: { member_id: member.id.to_s, tool_id: tool.id.to_s,
                        tool_name: tool.name, approved_by: current_member.fullname },
      slack_channel:  ::Service::SlackConnector.logs_channel
    )

    render json: checkout.as_json(
      serializer: ToolCheckoutSerializer,
      adapter: :attributes
    ).merge(unmet_prerequisites: unmet.map(&:name)), adapter: :attributes
  end

  def update
    # Only allow updating revocation fields
    if update_params[:revoked_at] || update_params[:revocation_reason]
      @checkout.update_attributes!(update_params)
      @checkout.send_revocation_slack_notification if @checkout.revoked_at.present?
    end
    render json: @checkout, serializer: ToolCheckoutSerializer, adapter: :attributes
  end

  def destroy
    reason = params[:revocation_reason].presence
    raise ::Error::UnprocessableEntity.new("Revocation reason is required") unless reason

    @checkout.update_attributes!(
      revoked_at: Time.now,
      revocation_reason: reason
    )
    @checkout.send_revocation_slack_notification

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'tool_checkout_revoked',
      resource_type:  'ToolCheckout',
      resource_id:    @checkout.id,
      actor:          current_member,
      subject:        @checkout.member,
      after_snapshot: { tool_id: @checkout.tool_id.to_s, revocation_reason: reason },
      slack_channel:  ::Service::SlackConnector.logs_channel
    )

    render json: @checkout, serializer: ToolCheckoutSerializer, adapter: :attributes
  end

  private

  def checkout_params
    params.require([:member_id, :tool_id])
    params.permit(:member_id, :tool_id)
  end

  def update_params
    params.permit(:revoked_at, :revocation_reason)
  end

  def find_checkout
    @checkout = ToolCheckout.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(ToolCheckout, { id: params[:id] }) if @checkout.nil?
  end

  def authorized?
    return if is_privileged?
    raise ::Error::Forbidden.new unless active_checkout_approver?
  end

  # Admins can approve/revoke anything. RMs and checkout approvers are shop-scoped.
  def authorize_approver
    return if is_admin? || is_board_member?
    tool = params[:tool_id].present? ? Tool.find(params[:tool_id]) : @checkout.tool
    shop_id = tool.try(:shop_id)

    return if is_resource_manager?

    approver = CheckoutApprover.find_by(member_id: current_member.id)
    unless approver && approver.can_approve_for_shop?(shop_id)
      render json: { error: "You are not authorized to approve checkouts for this shop" }, status: 403 and return
    end

    if action_name == 'destroy' && @checkout.approved_by_id.to_s != current_member.id.to_s
      render json: { error: "You may only revoke checkouts you approved" }, status: 403
    end
  end

  def active_checkout_approver?
    ToolCheckoutRequest.active_member?(current_member) && CheckoutApprover.exists?(member_id: current_member.id)
  end

  def approver_visible_tool_ids
    approver = CheckoutApprover.find_by(member_id: current_member.id)
    return [] unless approver

    approved_tool_ids = Tool.where(:shop_id.in => approver.shop_ids).pluck(:id)
    prerequisite_ids = Tool.where(:id.in => approved_tool_ids).pluck(:prerequisite_ids).flatten.compact
    (approved_tool_ids + prerequisite_ids).uniq
  end

  def unmet_prerequisites(member, tool)
    return [] if tool.prerequisite_ids.blank?
    checked_out_tool_ids = ToolCheckout.where(member_id: member.id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
    tool.prerequisite_ids.map(&:to_s).reject { |pid| checked_out_tool_ids.include?(pid) }.map do |pid|
      Tool.find(pid) rescue nil
    end.compact
  end
end
