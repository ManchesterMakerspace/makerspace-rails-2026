class Billing::PlansController < ApplicationController
  include BraintreeGateway
  include FastQuery::BraintreeQuery
  
  def index
    types = Array(plan_params[:types]).map(&:to_s).sort
    payload = Rails.cache.fetch(
      ["braintree", "plans", types],
      expires_in: 15.minutes,
      race_condition_ttl: 30.seconds
    ) do
      plans = ::BraintreeService::Plan.get_plans(@gateway)
      if plan_params[:types].present?
        plans = ::BraintreeService::Plan.select_plans_for_types(plan_params[:types], plans)
      end
      ActiveModelSerializers::SerializableResource.new(
        plans,
        each_serializer: BraintreeService::PlanSerializer,
        adapter: :attributes
      ).as_json
    end
    response.set_header("total-items", payload.length)
    render json: payload
  end

  private
  def plan_params
    params.permit(types: [])
  end
end
