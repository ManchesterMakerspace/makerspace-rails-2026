class ToolAvailabilityService
  ToolScope = Struct.new(:shop_id, :tool)
  def self.set!(tool:, actor:, value:)
    proxy = ToolScope.new(tool.shop_id, tool)
    raise Error::Forbidden.new unless FixTicketPolicy.new(actor, proxy).staff?
    raise Error::UnprocessableEntity.new('out_of_service must be a boolean') unless [true, false].include?(value)
    ReservationService.send(:with_shop_locks, [tool.shop_id]) do
      previous = !!tool.reload.out_of_service
      if previous != value
        tool.update!(out_of_service: value)
        Service::AuditLogger.log(log_type: 'portal', event_type: 'tool_availability_changed',
          resource_type: 'Tool', resource_id: tool.id, actor: actor,
          field_changes: { 'out_of_service' => [previous, value] })
      end
    end
    affected = Reservation.where(tool_ids: tool.id.to_s, :status.in => Reservation::ACTIVE_STATUSES, :end_at.gt => Time.current)
    affected.flat_map { |reservation| ReservationService.send(:slack_canvas_targets, reservation) }
      .uniq.group_by(&:first).each do |shop_id, targets|
        ReservationSlackCanvasSyncJob.perform_later(shop_id, targets.map { |(_, date)| date.iso8601 })
      end
    { outOfService: value, affectedReservations: affected.order_by(start_at: :asc).limit(100).map { |r| { id: r.id.to_s, startAt: r.start_at, endAt: r.end_at } },
      affectedCount: affected.count }
  end
end
