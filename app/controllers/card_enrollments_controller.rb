class CardEnrollmentsController < AuthenticationController
  before_action { response.set_header('Cache-Control', 'private, no-store') }
  rescue_from CardEnrollment::Invalid, with: :invalid
  rescue_from CardManagement::Conflict do |error|
    render json: { error: error.message }, status: :conflict
  end
  rescue_from CardManagement::Unavailable do |error|
    render json: { error: error.message }, status: :service_unavailable
  end

  def create
    service.authorize!
    render json: service.prepare!(params.require(:member_id), params.require(:uid), params[:id_verified])
  end

  def show
    render json: service.show(params[:id])
  end

  def commit
    render json: service.commit!(params[:id], params[:revision], params[:digest])
  end

  private

  def service
    @service ||= CardEnrollment.new(current_member, request.path.start_with?('/api/admin/') ? 'admin' : 'issuer')
  end

  def invalid(error)
    render json: { error: error.message }, status: :unprocessable_entity
  end
end
