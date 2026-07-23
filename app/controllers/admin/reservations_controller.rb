class Admin::ReservationsController < ApplicationController
  around_action :handle_unexpected_reservation_errors
  before_action :authenticate_member!
  before_action :authorize_manager
  before_action :find_reservation, except: [:index]
  before_action :authorize_reservation, except: [:index]

  def index
    reservations = Reservation.all
    reservations = reservations.where(:shop_id.in => managed_shop_ids) unless is_admin? || is_board_member?
    reservations = reservations.where(shop_id: params[:shop_id]) if params[:shop_id].present?
    if params[:status].present?
      statuses = params[:status] == "cancelled" ? %w[cancelled canceled] : [params[:status]]
      reservations = reservations.where(:status.in => statuses)
    end
    reservations = reservations.where(:end_at.gt => Time.current) if params[:future] == "true"

    render json: reservations.order_by(start_at: :asc),
      each_serializer: ReservationSerializer,
      adapter: :attributes,
      scope: current_member
  end

  def update
    target_shop_id = reservation_params[:shop_id].presence || @reservation.shop_id
    unless is_admin? || is_board_member? || manages_shop?(target_shop_id)
      raise ::Error::Forbidden.new("You are not authorized to move this reservation to the selected shop")
    end
    reservation = ReservationService.update!(reservation: @reservation, attributes: reservation_params)
    render json: reservation, serializer: ReservationSerializer, adapter: :attributes, scope: current_member
  end

  def preview
    target_shop_id = reservation_params[:shop_id].presence || @reservation.shop_id
    unless is_admin? || is_board_member? || manages_shop?(target_shop_id)
      raise ::Error::Forbidden.new("You are not authorized to manage reservations for the selected shop")
    end
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
    unless is_admin? || is_board_member? || (is_resource_manager? && managed_shop_ids.present?)
      raise ::Error::Forbidden.new(
        "You are not authorized to manage reservations. Checkout-approver access does not grant reservation-management access"
      )
    end
  end

  def authorize_reservation
    unless is_admin? || is_board_member? || manages_shop?(@reservation.shop_id)
      raise ::Error::Forbidden.new("You are not authorized to manage reservations for this shop")
    end
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

  def handle_unexpected_reservation_error(error)
    Rails.logger.error(
      "[ReservationManagerError] action=#{action_name} member_id=#{current_member&.id} " \
      "error=#{error.class}: #{error.message}\n#{Array(error.backtrace).first(10).join("\n")}"
    )
    Honeybadger.notify(error) if defined?(Honeybadger)
    render json: {
      status: 500,
      error: "internal_server_error",
      message: "The reservation could not be processed. Please try again or contact an administrator " \
        "with request ID #{Current.request_id}."
    }, status: :internal_server_error
  end

  def handle_unexpected_reservation_errors
    yield
  rescue ::Error::CustomError, ::Mongoid::Errors::MongoidError,
         ::ActionController::ParameterMissing, ::ActionController::InvalidAuthenticityToken
    raise
  rescue => error
    handle_unexpected_reservation_error(error)
  end
end
