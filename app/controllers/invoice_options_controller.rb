class InvoiceOptionsController < ApplicationController
  include FastQuery::MongoidQuery
  before_action :find_invoice_option, only: [:show]

  def index
    enabled_options = (is_admin? || invoice_option_params[:only_enabled]) ? InvoiceOption.all : InvoiceOption.where(disabled: false)
    if invoice_option_params[:subscription_only]
      enabled_options = enabled_options.where({ :plan_id.nin => ["", nil] })
    end
    invoice_option_types = invoice_option_params[:types]
    invoice_options = invoice_option_types ? enabled_options.where(:resource_class.in => invoice_option_types) : enabled_options
    cache_variant = [
      "subscription=#{to_bool(invoice_option_params[:subscription_only])}",
      "enabled=#{to_bool(invoice_option_params[:only_enabled])}",
      "types=#{Array(invoice_option_types).map(&:to_s).sort.join(',')}",
      "admin=#{is_admin?}"
    ].join("/")
    payload = CachedPayload.collection(
      "invoice_options/#{cache_variant}",
      invoice_options,
      serializer: InvoiceOptionSerializer,
      dependencies: ["invoice_options"]
    )
    response.set_header("total-items", payload.length)
    render json: payload
  end

  def show
    render json: @invoice_option, adapter: :attributes and return
  end

  private
  def invoice_option_params
    params.permit(:subscription_only, :only_enabled, :types => [])
  end

  def find_invoice_option
    @invoice_option = InvoiceOption.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(InvoiceOption, { id: params[:id] }) if @invoice_option.nil?
  end
end
