class Admin::InvoiceOptionsController < AdminOrRmController
  include FastQuery::MongoidQuery
  before_action :find_invoice_option, only: [:update, :destroy]
  before_action :authorize_fee_action, only: [:create, :update, :destroy]

  def create
    invoice_option = InvoiceOption.new(create_params)
    invoice_option.save!
    render json: invoice_option, each_serializer: InvoiceOptionSerializer, adapter: :attributes and return
  end

  def update
    @invoice_option.update_attributes!(invoice_params)
    render json: @invoice_option, adapter: :attributes and return
  end

  def destroy
    @invoice_option.destroy
    render json: {}, status: 204 and return
  end

  private

  # Admins can manage all invoice option types.
  # Resource Managers can only manage fee-type invoice options (the shop fee catalog).
  def authorize_fee_action
    return if is_admin?
    # For create: check incoming resource_class param
    # For update/destroy: check the existing record's resource_class
    target_class = @invoice_option ? @invoice_option.resource_class : params[:resource_class]
    unless target_class == "fee"
      render json: { error: "Resource managers may only manage shop fee catalog items" }, status: 403
    end
  end

  def create_params
    params.require([:name, :resource_class, :amount, :quantity])
    invoice_params
  end

  def invoice_params
    params.permit(:description, :name, :resource_class, :amount, :quantity, :disabled, :plan_id, :discount_id, :promotion_end_date)
  end

  def find_invoice_option
    @invoice_option = InvoiceOption.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(InvoiceOption, { id: params[:id] }) if @invoice_option.nil?
  end
end
