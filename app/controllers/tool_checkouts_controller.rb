class ToolCheckoutsController < ApplicationController
  before_action :authenticate_member!

  def index
    checkouts = ToolCheckout.where(member_id: current_member.id, revoked_at: nil)
    render json: checkouts, each_serializer: ToolCheckoutSerializer, adapter: :attributes
  end
end
