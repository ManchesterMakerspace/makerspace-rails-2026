class Admin::ToolCheckoutRequestsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorized?

  def index
    requests = ToolCheckoutRequest.where(:tool_id.in => Tool.pluck(:id)).order_by(created_at: :desc)

    unless is_admin? || is_board_member?
      approver = CheckoutApprover.find_by(member_id: current_member.id)
      shop_ids = approver.try(:shop_ids) || []
      tool_ids = Tool.where(:shop_id.in => shop_ids).pluck(:id)
      active_member_ids = Member.where(status: 'activeMember').any_of({ :expirationTime.gte => Time.now.to_i * 1000 }, { expirationTime: nil }).pluck(:id)
      requests = requests.where(status: 'open', :tool_id.in => tool_ids, :member_id.in => active_member_ids)
    end

    render json: requests, each_serializer: ToolCheckoutRequestSerializer, adapter: :attributes
  end

  private

  def authorized?
    return if is_admin? || is_board_member?
    approver = CheckoutApprover.find_by(member_id: current_member.id)
    raise ::Error::Forbidden.new unless approver.present?
  end
end
