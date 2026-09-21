class Admin::CheckoutApproversController < AdminController
  before_action :find_approver, only: [:update, :destroy]

  def index
    approvers = CheckoutApprover.all.to_a
    render json: approvers, each_serializer: CheckoutApproverSerializer, adapter: :attributes,
      checkout_context: CheckoutReadContext.for_approvers(approvers)
  end

  def create
    approver = CheckoutApproverMutationLock.with(member_id: approver_params[:member_id]) do
      record = CheckoutApprover.find_or_initialize_by(member_id: approver_params[:member_id])
      incoming_shops = approver_params[:shop_ids] || []
      incoming_tools = approver_params[:tool_ids] || []
      record.shop_ids = (record.shop_ids + incoming_shops).uniq
      record.tool_ids = (record.tool_ids + incoming_tools).uniq
      record.save!
      record
    end

    ::Service::AuditLogger.log(
      log_type:       'portal',
      event_type:     'checkout_approver_created',
      resource_type:  'CheckoutApprover',
      resource_id:    approver.id,
      actor:          current_member,
      after_snapshot: approver.attributes
    )

    render json: approver, serializer: CheckoutApproverSerializer, adapter: :attributes
  end

  def update
    before = nil
    CheckoutApproverMutationLock.with(member_id: @approver.member_id) do
      @approver.reload
      before = @approver.attributes.dup
      @approver.update_attributes!(approver_params)
    end

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'checkout_approver_updated',
      resource_type:   'CheckoutApprover',
      resource_id:     @approver.id,
      actor:           current_member,
      field_changes:   @approver.previous_changes,
      before_snapshot: before,
      after_snapshot:  @approver.attributes
    )

    render json: @approver, serializer: CheckoutApproverSerializer, adapter: :attributes
  end

  def destroy
    before = nil
    CheckoutApproverMutationLock.with(member_id: @approver.member_id) do
      @approver.reload
      before = @approver.attributes.dup
      @approver.destroy
    end

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'checkout_approver_deleted',
      resource_type:   'CheckoutApprover',
      resource_id:     before['_id'],
      actor:           current_member,
      before_snapshot: before,
      after_snapshot:  {}
    )

    render json: {}, status: 204
  end

  private

  def approver_params
    params.permit(:member_id, shop_ids: [], tool_ids: [])
  end

  def find_approver
    @approver = CheckoutApprover.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(CheckoutApprover, { id: params[:id] }) if @approver.nil?
  end
end
