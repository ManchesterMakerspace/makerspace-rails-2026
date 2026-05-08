# Admin::VolunteerCreditsController
#
# Admin and Resource Managers can:
#   - List all credits (index)
#   - Award a one-off credit to any member (create) — always 1.0 credit, auto-approved
#   - Approve or reject a pending credit (approve / reject)
#   - Destroy a credit (admin only)
#
# Admins and RMs cannot approve credits for themselves.
# Earned membership members may receive credits but they never trigger discounts.
#
class Admin::VolunteerCreditsController < AdminOrRmController
  before_action :find_credit, only: [:approve, :reject, :destroy]

  # GET /api/admin/volunteer_credits
  def index
    credits = VolunteerCredit.all.order_by(created_at: :desc)
    credits = credits.where(member_id: params[:member_id]) if params[:member_id].present?
    credits = credits.where(status: params[:status])       if params[:status].present?

    render json: credits, each_serializer: VolunteerCreditSerializer, adapter: :attributes
  end

  # POST /api/admin/volunteer_credits
  # Award a one-off credit directly — always 1.0 credit, auto-approved.
  # For variable credit values, use a bounty task instead.
  def create
    member = Member.find(credit_params[:member_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: credit_params[:member_id] }) if member.nil?
    raise ::Error::Forbidden.new if member.id == current_member.id

    credit = VolunteerCredit.new(
      member_id:    member.id,
      issued_by_id: current_member.id,
      description:  credit_params[:description],
      credit_value: 1.0,
      status:       'approved'
    )
    credit.save!
    credit.send(:notify_member_credit_awarded)
    credit.send(:check_discount_threshold!)

    render json: credit, serializer: VolunteerCreditSerializer, adapter: :attributes
  end

  # POST /api/admin/volunteer_credits/:id/approve
  def approve
    @credit.approve!(current_member)
    render json: @credit, serializer: VolunteerCreditSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'You cannot approve your own credit' }, status: :forbidden
  end

  # POST /api/admin/volunteer_credits/:id/reject
  def reject
    @credit.reject!(current_member)
    render json: @credit, serializer: VolunteerCreditSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'You cannot reject your own credit' }, status: :forbidden
  end

  # DELETE /api/admin/volunteer_credits/:id
  def destroy
    raise ::Error::Forbidden.new unless is_admin?
    @credit.destroy
    render json: {}, status: :no_content
  end

  private

  def find_credit
    @credit = VolunteerCredit.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(VolunteerCredit, { id: params[:id] }) if @credit.nil?
  end

  def credit_params
    params.permit(:member_id, :description)
  end
end
