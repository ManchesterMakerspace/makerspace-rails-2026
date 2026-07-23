class Admin::ShopsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorize_index, only: [:index]
  before_action :authorize_create_destroy, only: [:create, :destroy]
  before_action :find_shop, only: [:update, :destroy]
  before_action :authorize_update, only: [:update]

  def index
    shops = if is_admin? || is_board_member?
      Shop.all
    else
      Shop.where(:id.in => managed_shop_ids)
    end
    shops = shops.order_by(name: :asc)
    render json: shops, each_serializer: ShopSerializer, adapter: :attributes
  end

  def create
    shop = Shop.new(shop_params)
    shop.save!
    GoogleResourceSyncJob.perform_later("Shop", shop.id.to_s)

    ::Service::AuditLogger.log(
      log_type:       'portal',
      event_type:     'shop_created',
      resource_type:  'Shop',
      resource_id:    shop.id,
      actor:          current_member,
      after_snapshot: shop.attributes
    )

    render json: shop, serializer: ShopSerializer, adapter: :attributes
  end

  def update
    before = @shop.attributes.dup
    @shop.update_attributes!(shop_params)
    if @shop.resource_email.blank? || @shop.previous_changes.key?("name") || @shop.previous_changes.key?("reservable")
      GoogleResourceSyncJob.perform_later("Shop", @shop.id.to_s)
    end

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'shop_updated',
      resource_type:   'Shop',
      resource_id:     @shop.id,
      actor:           current_member,
      field_changes:   @shop.previous_changes,
      before_snapshot: before,
      after_snapshot:  @shop.attributes
    )

    render json: @shop, serializer: ShopSerializer, adapter: :attributes
  end

  def destroy
    if Reservation.blocking.where(shop_id: @shop.id, :end_at.gt => Time.current).exists?
      raise ::Error::Conflict.new("Cancel future reservations before deleting this shop")
    end
    before = @shop.attributes.dup
    deleted_tool_ids = @shop.tools.pluck(:id).map(&:to_s)
    google_resource_ids = [@shop.google_resource_id] + @shop.tools.pluck(:google_resource_id)
    @shop.destroy
    google_resource_ids.compact.each { |resource_id| GoogleResourceDeleteJob.perform_later(resource_id) }
    Member.where(role: "resource_manager", :resource_manager_shop_ids.in => [before["_id"].to_s]).each do |member|
      member.pull(resource_manager_shop_ids: before["_id"].to_s)
    end
    CheckoutApprover.where(:shop_ids.in => [before["_id"].to_s]).each do |approver|
      approver.pull(shop_ids: before["_id"].to_s)
      approver.destroy if approver.shop_ids.blank? && approver.tool_ids.blank?
    end
    CheckoutApprover.where(:tool_ids.in => deleted_tool_ids).each do |approver|
      approver.set(tool_ids: Array(approver.tool_ids).map(&:to_s) - deleted_tool_ids)
      approver.destroy if approver.shop_ids.blank? && approver.tool_ids.blank?
    end

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'shop_deleted',
      resource_type:   'Shop',
      resource_id:     before['_id'],
      actor:           current_member,
      before_snapshot: before,
      after_snapshot:  {}
    )

    render json: {}, status: 204
  end

  private

  def shop_params
    params.permit(
      :name, :slack_channel, :disabled, :reservable,
      :max_concurrent_reservations, :reservation_horizon_days,
      :max_reservation_duration_hours, :reservation_requires_approval,
      reservation_prerequisite_tool_ids: []
    )
  end

  def find_shop
    @shop = Shop.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Shop, { id: params[:id] }) if @shop.nil?
  end

  def authorize_index
    raise ::Error::Forbidden.new unless is_admin? || is_board_member? || is_resource_manager?
  end

  def authorize_create_destroy
    raise ::Error::Forbidden.new unless is_admin? || is_board_member?
  end

  def authorize_update
    raise ::Error::Forbidden.new unless can_manage_shop?(@shop)
  end
end
