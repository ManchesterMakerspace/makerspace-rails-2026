# Private service endpoint. Deliberately independent of browser sessions/CSRF.
class ReaderReservationsController < ActionController::API
  def sync
    expected = ENV['READER_RESERVATION_SERVICE_SECRET'].to_s
    supplied = request.authorization.to_s.delete_prefix('Bearer ')
    unless expected.length >= 32 && ActiveSupport::SecurityUtils.secure_compare(supplied, expected)
      return render json: { error: 'Service authentication required' }, status: :unauthorized
    end
    return render json: { error: 'Request too large' }, status: :payload_too_large if request.raw_post.bytesize > 16_384
    body = JSON.parse(request.raw_post)
    result = ReaderReservationService.sync!(body)
    render json: result
  rescue JSON::ParserError, ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue ReaderReservationService::Conflict => e
    render json: { error: e.message }, status: :conflict
  end
end
