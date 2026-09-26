class Admin::LocationsController < ApplicationController
  before_action :authenticate_member!
  before_action :find_location, only: [:update, :destroy]
  before_action :authorize_create, only: [:create]
  before_action :authorize_manage, only: [:update, :destroy]

  def index
    locations = params[:shop_id] ? Location.where(shop_id: params[:shop_id]) : Location.all
    locations = locations.where(:shop_id.in => managed_shop_ids) unless is_admin? || is_board_member?
    render json: locations.to_a, each_serializer: LocationSerializer, adapter: :attributes
  end

  def create
    location = Location.new(location_params)
    location.save!

    ::Service::AuditLogger.log(
      log_type:       'portal',
      event_type:     'location_created',
      resource_type:  'Location',
      resource_id:    location.id,
      actor:          current_member,
      after_snapshot: location.attributes
    )

    render json: location, serializer: LocationSerializer, adapter: :attributes
  end

  def update
    before = @location.attributes.dup
    @location.update_attributes!(location_params)

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'location_updated',
      resource_type:   'Location',
      resource_id:     @location.id,
      actor:           current_member,
      field_changes:   @location.previous_changes,
      before_snapshot: before,
      after_snapshot:  @location.attributes
    )

    render json: @location, serializer: LocationSerializer, adapter: :attributes
  end

  def destroy
    before = @location.attributes.dup
    @location.destroy

    ::Service::AuditLogger.log(
      log_type:        'portal',
      event_type:      'location_deleted',
      resource_type:   'Location',
      resource_id:     before['_id'],
      actor:           current_member,
      before_snapshot: before,
      after_snapshot:  {}
    )

    render json: {}, status: 204
  end

  private

  def location_params
    params.permit(:name, :kind, :parent_id, :shop_id, :svg_element_id, :x_pct, :y_pct)
  end

  def find_location
    @location = Location.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Location, { id: params[:id] }) if @location.nil?
  end

  def authorize_create
    shop = Shop.find(location_params[:shop_id])
    raise ::Error::Forbidden.new("User cannot manage this shop") unless can_manage_shop?(shop)
  end

  def authorize_manage
    raise ::Error::Forbidden.new("User cannot manage this shop") unless can_manage_shop?(@location.shop_id)

    target_shop_id = location_params[:shop_id].presence
    if target_shop_id && !can_manage_shop?(target_shop_id)
      raise ::Error::Forbidden.new("User cannot move this location to that shop")
    end
  end
end
