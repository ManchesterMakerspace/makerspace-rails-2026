class Billing::DiscountsController < ApplicationController
  include BraintreeGateway
  include FastQuery::BraintreeQuery
  
  def index
    types = Array(discount_params[:types]).map(&:to_s).sort
    payload = Rails.cache.fetch(
      ["braintree", "discounts", types],
      expires_in: 15.minutes,
      race_condition_ttl: 30.seconds
    ) do
      discounts = ::BraintreeService::Discount.get_discounts(@gateway)
      if discount_params[:types].present?
        discounts = ::BraintreeService::Discount.select_discounts_for_types(
          discount_params[:types],
          discounts
        )
      end
      ActiveModelSerializers::SerializableResource.new(
        discounts,
        each_serializer: BraintreeService::DiscountSerializer,
        adapter: :attributes
      ).as_json
    end
    response.set_header("total-items", payload.length)
    render json: payload
  end

  private
  def discount_params
    params.permit(types: [])
  end
end
