class ShopsController < ApplicationController
  before_action :authenticate_member!

  def index
    payload = CachedPayload.collection(
      "shops/public",
      Shop.all.order_by(name: :asc),
      serializer: ShopSerializer,
      dependencies: ["shops", "tools"]
    )
    render json: payload
  end
end
