class Admin::ToolsController < AdminOrRmController
  before_action :find_tool, only: [:update, :destroy]

  def index
    tools = params[:shop_id] ? Tool.where(shop_id: params[:shop_id]) : Tool.all
    tools = tools.order_by(name: :asc)
    render json: tools, each_serializer: ToolSerializer, adapter: :attributes
  end

  def create
    tool = Tool.new(tool_params)
    tool.save!
    render json: tool, serializer: ToolSerializer, adapter: :attributes
  end

  def update
    @tool.update_attributes!(tool_params)
    render json: @tool, serializer: ToolSerializer, adapter: :attributes
  end

  def destroy
    @tool.destroy
    render json: {}, status: 204
  end

  private

  def tool_params
    params.permit(:name, :description, :shop_id, :disabled, prerequisite_ids: [])
  end

  def find_tool
    @tool = Tool.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Tool, { id: params[:id] }) if @tool.nil?
  end
end
