class ReservationsController < ApplicationController
  around_action :handle_unexpected_reservation_errors
  before_action :authenticate_member!
  before_action :require_active_member, only: [:availability, :preview, :create, :update]
  before_action :find_reservation, only: [:update, :destroy]
  before_action :authorize_owner, only: [:update, :destroy]

  def index
    reservations = Reservation.where(member_id: current_member.id)
    reservations = reservations.where(shop_id: params[:shop_id]) if params[:shop_id].present?
    if params[:status].present?
      statuses = params[:status] == "cancelled" ? %w[cancelled canceled] : [params[:status]]
      reservations = reservations.where(:status.in => statuses)
    end
    reservations = reservations.where(:end_at.gt => parse_time(params[:start_at])) if params[:start_at].present?
    reservations = reservations.where(:start_at.lt => parse_time(params[:end_at])) if params[:end_at].present?
    render json: reservations.order_by(start_at: :asc),
      each_serializer: ReservationSerializer,
      adapter: :attributes,
      scope: current_member
  end

  def preview
    render json: ReservationService.preview(
      member: current_member,
      attributes: reservation_params
    )
  end

  def availability
    day = Date.iso8601(params.require(:date))
    day_start = ReservationService::ZONE.local(day.year, day.month, day.day).utc
    next_day = day + 1
    day_end = ReservationService::ZONE.local(next_day.year, next_day.month, next_day.day).utc
    reservations = Reservation.blocking.where(:start_at.lt => day_end, :end_at.gt => day_start)
    reservations = reservations.where(shop_id: params[:shop_id]) if params[:shop_id].present?

    render json: reservations.order_by(start_at: :asc),
      each_serializer: ReservationSerializer,
      adapter: :attributes,
      scope: current_member
  rescue Date::Error
    raise ::Error::UnprocessableEntity.new("Invalid reservation date")
  end

  def create
    reservation = ReservationService.create!(
      member: current_member,
      attributes: reservation_params,
      source: "portal"
    )
    if is_board_member?
      ::Service::AuditLogger.log(
        log_type: "portal",
        event_type: "board_reservation_created",
        resource_type: "Reservation",
        resource_id: reservation.id,
        actor: current_member,
        subject: current_member,
        after_snapshot: reservation.attributes
      )
    end
    render json: reservation, serializer: ReservationSerializer, adapter: :attributes,
      scope: current_member, status: :created
  end

  def update
    ensure_future!
    reservation = ReservationService.update!(reservation: @reservation, attributes: reservation_params)
    render json: reservation, serializer: ReservationSerializer, adapter: :attributes, scope: current_member
  end

  def destroy
    ensure_future!
    reservation = ReservationService.cancel!(reservation: @reservation, actor: current_member)
    render json: reservation, serializer: ReservationSerializer, adapter: :attributes, scope: current_member
  end

  private

  def reservation_params
    params.permit(:title, :shop_id, :reservation_scope, :start_at, :end_at, tool_ids: [])
  end

  def find_reservation
    @reservation = Reservation.find(params[:id])
  end

  def authorize_owner
    unless @reservation.member_id.to_s == current_member.id.to_s
      raise ::Error::Forbidden.new("You may only edit or cancel reservations that you created")
    end
  end

  def ensure_future!
    unless @reservation.end_at > Time.current && Reservation::ACTIVE_STATUSES.include?(@reservation.status)
      raise ::Error::UnprocessableEntity.new("Only future active reservations can be changed")
    end
  end

  def require_active_member
    return if current_member.role.in?(%w[admin board_member])
    return if current_member.role == "resource_manager" &&
      current_member.resource_manager_shop_ids.present?
    return if current_member.active_unexpired?

    raise ::Error::Forbidden.new(
      "Your membership is inactive or expired. You may view and cancel existing reservations, but cannot create or edit reservations"
    )
  end

  def parse_time(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    raise ::Error::UnprocessableEntity.new("Invalid reservation date")
  end

  def handle_unexpected_reservation_error(error)
    Rails.logger.error(
      "[ReservationError] action=#{action_name} member_id=#{current_member&.id} " \
      "error=#{error.class}: #{error.message}\n#{Array(error.backtrace).first(10).join("\n")}"
    )
    Honeybadger.notify(error) if defined?(Honeybadger)
    render json: {
      status: 500,
      error: "internal_server_error",
      message: "The reservation could not be #{action_name == 'destroy' ? 'cancelled' : 'processed'}. " \
        "Please try again or contact an administrator with request ID #{Current.request_id}."
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
