class Admin::CheckoutApproversController < AdminController
  before_action :find_approver, only: [:update, :destroy]

  def index
    approvers = CheckoutApprover.all
    render json: approvers, each_serializer: CheckoutApproverSerializer, adapter: :attributes
  end

  def create
    approver = CheckoutApprover.find_or_initialize_by(member_id: approver_params[:member_id])
    # Merge incoming shop IDs with any existing ones (React sends full list on edit,
    # but merge here as a safety net against accidental data loss)
    incoming = approver_params[:shop_ids] || []
    approver.shop_ids = (approver.shop_ids + incoming).uniq
    approver.save!
    render json: approver, serializer: CheckoutApproverSerializer, adapter: :attributes
  end

  def update
    # PUT replaces the shop list entirely — used for explicit edit from the UI
    @approver.update_attributes!(approver_params)
    render json: @approver, serializer: CheckoutApproverSerializer, adapter: :attributes
  end

  def destroy
    @approver.destroy
    render json: {}, status: 204
  end

  private

  def approver_params
    params.permit(:member_id, shop_ids: [])
  end

  def find_approver
    @approver = CheckoutApprover.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(CheckoutApprover, { id: params[:id] }) if @approver.nil?
  end
end
