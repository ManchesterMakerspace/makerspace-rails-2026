class ToolCheckoutRequestsController < AuthenticationController
  include CatalogUnavailable
  prepend_before_action { response.set_header("Cache-Control", "private, no-store") }

  before_action :find_request, only: [:update, :destroy]

  def index
    requests = CheckoutInteractionQuery.new(member: current_member).open_requests

    requests = ToolCheckoutRequest.table_query(requests, params)
    response.set_header("total-items", requests.count)

    render json: requests,
      each_serializer: ToolCheckoutRequestSerializer,
      adapter: :attributes
  end

  def create
    tool, = PublicCatalog.tool(request_params[:tool_id], public_only: false)
    request = CheckoutRequestCreation.create!(member_id: current_member.id, tool_id: tool.id,
      shop_id: tool.shop_id, note: request_params[:note])

    render json: request, serializer: ToolCheckoutRequestSerializer, adapter: :attributes
  end

  def update
    mutate_request! { @request.update_attributes!(request_params.slice(:note)) }
    render json: @request, serializer: ToolCheckoutRequestSerializer, adapter: :attributes
  end

  def destroy
    mutate_request! { @request.update_attributes!(status: "deleted") }
    CheckoutCreation.notify { @request.remove_announcement }
    render json: {}, status: 204
  end

  private

  def mutate_request!
    CheckoutMutationLock.with(member_id: @request.member_id, tool_id: @request.tool_id) do
      @request.reload
      raise Error::Forbidden.new unless @request.member_id == current_member.id && @request.open?
      tool = @request.tool
      raise Error::Forbidden.new unless tool && !tool.disabled? && tool.shop && !tool.shop.disabled?
      yield
    end
  end

  def request_params
    params.permit(:tool_id, :note)
  end

  def find_request
    @request = ToolCheckoutRequest.find(params[:id])
    raise Error::NotFound.new unless @request
  end

end
