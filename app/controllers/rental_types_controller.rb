class RentalTypesController < AuthenticationController
  def index
    payload = CachedPayload.collection(
      "rental_types/active",
      RentalType.where(active: true),
      serializer: RentalTypeSerializer,
      dependencies: ["rental_types", "invoice_options"]
    )
    render json: payload.to_json
  end
end
