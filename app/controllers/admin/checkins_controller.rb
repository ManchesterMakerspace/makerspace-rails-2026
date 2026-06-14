class Admin::CheckinsController < AuthenticationController
  before_action :authorize_checkin_access

  def index
    checkins = mask_uids(checkins_collection.find(checkins_query).to_a)
    render json: { checkins: checkins } and return
  end

  private

  def checkins_collection
    Mongoid.default_client[:checkins]
  end

  def checkins_query
    query = {}

    # Build time range — checks timeOf and time fields under BOTH unit
    # interpretations (seconds and milliseconds), since either field may
    # store either unit depending on the record. See CheckinTimeHelper.
    if query_start_time || query_end_time
      # Use $and to safely combine uid filter with $or time field conditions
      query['$and'] = [
        { 'uid' => { '$in' => query_uids } },
        { '$or' => CheckinTimeHelper.dual_unit_or_query(query_start_time, query_end_time) }
      ]
    else
      query['uid'] = { '$in' => query_uids }
    end

    query
  end

  def authorize_checkin_access
    return if is_admin? || is_resource_manager? || is_board_member?

    # Regular members may only see their own card activity. Ignore any requested
    # UIDs instead of rejecting so callers cannot probe other members' cards.
    params.delete(:uids)
  end

  def query_uids
    @query_uids ||= begin
      if is_admin? || is_resource_manager? || is_board_member?
        parsed = JSON.parse(params.require(:uids))
        raise Error::UnprocessableEntity.new('uids must be an array') unless parsed.is_a?(Array)
        parsed.map(&:to_s)
      else
        current_member.access_cards.map(&:uid).map(&:to_s)
      end
    end
  end

  def mask_uids(records)
    return records if is_admin? || is_board_member?

    uid_map = Card.where(:uid.in => records.map { |record| record['uid'].to_s }).to_a.index_by { |card| card.uid.to_s }
    records.map do |record|
      masked = record.dup
      card = uid_map[masked['uid'].to_s]
      masked['uid'] = card.id.to_s if card
      masked
    end
  end

  def query_start_time
    return nil if params[:startTime].blank?
    params[:startTime].to_i
  end

  def query_end_time
    return nil if params[:endTime].blank?
    params[:endTime].to_i
  end
end
