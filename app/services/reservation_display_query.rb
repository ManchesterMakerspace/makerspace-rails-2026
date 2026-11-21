# Read-only projections for Slack summaries and canvases. These values must never
# be used to authorize a reservation or replace the locked fee reconciliation.
module ReservationDisplayQuery
  RESERVATION_FIELDS = %i[id shop_id member_id title reservation_scope tool_ids
    start_at end_at status full_day group_snapshots calendar_html_link].freeze
  TOOL_FIELDS = %i[id shop_id name users_channel reservable disabled out_of_service].freeze
  SHOP_FIELDS = %i[id name slack_channel slack_announce_empty_reservations reservable
    disabled out_of_service canvas_today announcement_test_canvas_today].freeze
  BLACKOUT_FIELDS = %i[id shop_id title recurrence weekday start_time end_time start_date end_date].freeze

  def self.reservations(criteria)
    criteria.only(*RESERVATION_FIELDS).order_by(start_at: :asc, id: :asc).to_a
  end

  def self.member_names(member_ids)
    ids = Array(member_ids).compact.uniq
    return {} if ids.empty?

    # pluck avoids Member's after_initialize group synchronization, which can
    # query and persist unrelated membership data when a display loads a name.
    Member.where(:id.in => ids).pluck(:id, :firstname, :lastname).to_h do |id, first, last|
      [id.to_s, "#{first} #{last}"]
    end
  end

  def self.blackouts(shop_ids:, start_at:, end_at:)
    ids = Array(shop_ids).compact.uniq
    return [] if ids.empty?

    # Yesterday's occurrence may run overnight into this window. The date
    # bounds only remove impossible rules; Ruby still expands recurrence/DST.
    first_date = start_at.in_time_zone(ReservationService::ZONE).to_date - 1.day
    last_date = end_at.in_time_zone(ReservationService::ZONE).to_date
    ReservationBlackout.where(:shop_id.in => ids).and(
      { '$or' => [{ start_date: nil }, { :start_date.lte => last_date }] },
      { '$or' => [{ end_date: nil }, { :end_date.gte => first_date }] }
    ).only(*BLACKOUT_FIELDS).to_a
  end
end
