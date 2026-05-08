class Admin::ShopsController < AdminOrRmController
  before_action :find_shop, only: [:update, :destroy]

  def index
    shops = Shop.all.order_by(name: :asc)
    render json: shops, each_serializer: ShopSerializer, adapter: :attributes
  end

  def create
    shop = Shop.new(shop_params)
    shop.save!
    render json: shop, serializer: ShopSerializer, adapter: :attributes
  end

  def update
    @shop.update_attributes!(shop_params)
    render json: @shop, serializer: ShopSerializer, adapter: :attributes
  end

  def destroy
    @shop.destroy
    render json: {}, status: 204
  end

  private

  def shop_params
    params.permit(:name, :slack_channel, :disabled)
  end

  def find_shop
    @shop = Shop.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Shop, { id: params[:id] }) if @shop.nil?
  end
end
