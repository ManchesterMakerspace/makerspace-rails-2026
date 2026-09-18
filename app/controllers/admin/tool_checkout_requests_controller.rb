class Admin::ToolCheckoutRequestsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorize_view

  def index
    requests = CheckoutInteractionQuery.new(member: current_member).open_requests(for_approval: true)

    requests = ToolCheckoutRequest.table_query(requests, params)
    response.set_header("total-items", requests.count)

    render json: requests,
      each_serializer: ToolCheckoutRequestSerializer,
      adapter: :attributes
  end

  private

  def authorize_view
    raise ::Error::Forbidden.new unless is_admin? || is_board_member? ||
      managed_shop_ids.present? || is_valid_checkout_approver?
  end
end
