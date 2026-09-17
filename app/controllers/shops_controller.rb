class ShopsController < ApplicationController
  before_action :authenticate_member!

  def index
    shops = Shop.all.order_by(name: :asc)
    render json: shops.to_a, each_serializer: ShopSerializer, adapter: :attributes,
      checkout_context: CheckoutReadContext.for_shops(shops.to_a)
  end
end
