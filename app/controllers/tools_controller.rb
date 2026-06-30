class ToolsController < ApplicationController
  before_action :authenticate_member!

  def index
    tools = params[:shop_id] ? Tool.where(shop_id: params[:shop_id]) : Tool.all
    tools = tools.order_by(name: :asc)
    render json: tools, each_serializer: ToolSerializer, adapter: :attributes
  end
end
