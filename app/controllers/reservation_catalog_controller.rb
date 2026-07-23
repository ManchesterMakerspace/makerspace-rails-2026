class ReservationCatalogController < ApplicationController
  before_action :authenticate_member!
  before_action :require_active_member

  def index
    tools = Tool.where(:disabled.ne => true, reservable: true).order_by(name: :asc)
    shop_ids = tools.pluck(:shop_id)
    shops = Shop.where(:disabled.ne => true).any_of(
      { reservable: true },
      { :id.in => shop_ids }
    ).order_by(name: :asc)

    render json: {
      shops: ActiveModelSerializers::SerializableResource.new(
        shops, each_serializer: ShopSerializer, adapter: :attributes
      ),
      tools: ActiveModelSerializers::SerializableResource.new(
        tools, each_serializer: ToolSerializer, adapter: :attributes
      )
    }
  end

  private

  def require_active_member
    raise ::Error::Forbidden.new("Active membership is required") unless current_member.active_unexpired?
  end
end
