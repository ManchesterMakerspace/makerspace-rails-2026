class Admin::ReservationsController < ApplicationController
  before_action :authenticate_member!
  before_action :authorize_manager
  before_action :find_reservation, except: [:index]
  before_action :authorize_reservation, except: [:index]

  def index
    reservations = Reservation.all
    reservations = reservations.where(:shop_id.in => managed_shop_ids) unless is_admin? || is_board_member?
    reservations = reservations.where(shop_id: params[:shop_id]) if params[:shop_id].present?
    reservations = reservations.where(status: params[:status]) if params[:status].present?
    reservations = reservations.where(:end_at.gt => Time.current) if params[:future] == "true"

    render json: reservations.order_by(start_at: :asc),
      each_serializer: ReservationSerializer,
      adapter: :attributes,
      scope: current_member
  end

  def update
    target_shop_id = reservation_params[:shop_id].presence || @reservation.shop_id
    raise ::Error::Forbidden.new unless is_admin? || is_board_member? || manages_shop?(target_shop_id)
    reservation = ReservationService.update!(reservation: @reservation, attributes: reservation_params)
    render json: reservation, serializer: ReservationSerializer, adapter: :attributes, scope: current_member
  end

  def preview
    target_shop_id = reservation_params[:shop_id].presence || @reservation.shop_id
    raise ::Error::Forbidden.new unless is_admin? || is_board_member? || manages_shop?(target_shop_id)
    render json: ReservationService.preview(
      member: @reservation.member,
      attributes: reservation_params,
      reservation: @reservation
    )
  end

  def destroy
    reservation = ReservationService.cancel!(reservation: @reservation, actor: current_member)
    render json: reservation, serializer: ReservationSerializer, adapter: :attributes, scope: current_member
  end

  def approve
    reservation = ReservationService.approve!(
      reservation: @reservation,
      actor: current_member,
      note: decision_params[:decision_note]
    )
    ReservationDecisionNotificationJob.perform_later(reservation.id.to_s)
    render json: reservation, serializer: ReservationSerializer, adapter: :attributes, scope: current_member
  end

  def deny
    reservation = ReservationService.deny!(
      reservation: @reservation,
      actor: current_member,
      note: decision_params[:decision_note]
    )
    ReservationDecisionNotificationJob.perform_later(reservation.id.to_s)
    render json: reservation, serializer: ReservationSerializer, adapter: :attributes, scope: current_member
  end

  private

  def authorize_manager
    raise ::Error::Forbidden.new unless is_admin? || is_board_member? ||
      (is_resource_manager? && managed_shop_ids.present?)
  end

  def authorize_reservation
    raise ::Error::Forbidden.new unless is_admin? || is_board_member? || manages_shop?(@reservation.shop_id)
  end

  def find_reservation
    @reservation = Reservation.find(params[:id])
  end

  def reservation_params
    params.permit(:title, :shop_id, :reservation_scope, :start_at, :end_at, tool_ids: [])
  end

  def decision_params
    params.permit(:decision_note)
  end
end
