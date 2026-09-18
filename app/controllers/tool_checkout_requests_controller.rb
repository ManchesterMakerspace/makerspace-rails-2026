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
    eligibility = ToolCheckoutRequestEligibility.new(member: current_member, tool: tool)
    if eligibility.error
      error_class = eligibility.membership_ineligible? ? ::Error::Forbidden : ::Error::UnprocessableEntity
      raise error_class.new(eligibility.error)
    end

    request = ToolCheckoutRequest.create!(
      member_id: current_member.id,
      tool_id: tool.id,
      note: request_params[:note],
      request_date: Time.now,
      status: "open"
    )
    request.announce_request

    render json: request, serializer: ToolCheckoutRequestSerializer, adapter: :attributes
  end

  def update
    raise ::Error::Forbidden.new unless @request.member_id.to_s == current_member.id.to_s && @request.open?
    raise ::Error::Forbidden.new if @request.tool.try(:disabled?)

    @request.update_attributes!(request_params.slice(:note))
    render json: @request, serializer: ToolCheckoutRequestSerializer, adapter: :attributes
  end

  def destroy
    raise ::Error::Forbidden.new unless @request.member_id.to_s == current_member.id.to_s && @request.open?
    raise ::Error::Forbidden.new if @request.tool.try(:disabled?)

    @request.remove_announcement
    @request.update_attributes!(status: "deleted")
    render json: {}, status: 204
  end

  private

  def request_params
    params.permit(:tool_id, :note)
  end

  def find_request
    @request = ToolCheckoutRequest.find(params[:id])
  end

end
