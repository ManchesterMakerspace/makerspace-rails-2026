class ToolAvailabilityService
  def self.set!(tool:, actor:, value:)
    proxy = FixTicket.new(shop_id: tool.shop_id, tool_id: tool.id)
    raise Error::Forbidden.new unless FixTicketPolicy.new(actor, proxy).staff?
    raise Error::UnprocessableEntity.new('out_of_service must be a boolean') unless [true, false].include?(value)
    ReservationService.send(:with_shop_locks, [tool.shop_id]) do
      tool.reload.update!(out_of_service: value)
    end
    affected = Reservation.where(tool_ids: tool.id.to_s, :status.in => Reservation::ACTIVE_STATUSES, :end_at.gt => Time.current)
    { outOfService: value, affectedReservations: affected.order_by(start_at: :asc).limit(100).map { |r| { id: r.id.to_s, startAt: r.start_at, endAt: r.end_at } },
      affectedCount: affected.count }
  end
end
