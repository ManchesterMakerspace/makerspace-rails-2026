class Admin::ToolCheckoutRequestsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorize_view

  def index
    requests = ToolCheckoutRequest.where(status: "open")

    if can_view_disabled_tools?
      requests = requests.where(:tool_id.in => Tool.all.pluck(:id))
    else
      approver_shop_ids = CheckoutApprover.shops_for_member(current_member.id).map(&:id)
      tool_ids = Tool.where(:shop_id.in => approver_shop_ids, :disabled.ne => true).pluck(:id)
      valid_member_ids = Member.all.select(&:active_unexpired?).map(&:id)
      requests = requests.where(:tool_id.in => tool_ids, :member_id.in => valid_member_ids)
    end

    render json: requests.order_by(request_date: :asc),
      each_serializer: ToolCheckoutRequestSerializer,
      adapter: :attributes
  end

  private

  def authorize_view
    raise ::Error::Forbidden.new unless can_view_disabled_tools? || is_valid_checkout_approver?
  end
end
