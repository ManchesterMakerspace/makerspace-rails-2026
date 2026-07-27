class ReservationCatalogController < ApplicationController
  before_action :authenticate_member!
  before_action :require_active_member

  def index
    payload = MongoCache.fetch(
      "reservation_catalog",
      dependencies: ["reservation_catalog", "shops", "tools"]
    ) do
      enabled_shops = Shop.where(:disabled.ne => true)
      enabled_shop_ids = enabled_shops.pluck(:id).to_a
      tools = Tool.where(
        :disabled.ne => true,
        reservable: true,
        :shop_id.in => enabled_shop_ids
      ).order_by(name: :asc).to_a
      shop_ids = tools.map(&:shop_id).uniq
      shops = enabled_shops.any_of(
        { reservable: true },
        { :id.in => shop_ids }
      ).order_by(name: :asc).to_a

      {
        shops: ActiveModelSerializers::SerializableResource.new(
          shops, each_serializer: ShopSerializer, adapter: :attributes
        ).as_json,
        tools: ActiveModelSerializers::SerializableResource.new(
          tools, each_serializer: ToolSerializer, adapter: :attributes
        ).as_json
      }
    end

    render json: payload
  end

  private

  def require_active_member
    return if current_member.role.in?(%w[admin board_member])
    return if current_member.role == "resource_manager" &&
      current_member.resource_manager_shop_ids.present?
    return if current_member.active_unexpired?

    raise ::Error::Forbidden.new("Active membership is required")
  end
end
