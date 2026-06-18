class Admin::CheckinsController < AuthenticationController
  def index
    checkins = checkins_collection.find(checkins_query).to_a
    render json: { checkins: serialized_checkins(checkins) } and return
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
        { 'uid' => { '$in' => permitted_query_uids } },
        { '$or' => CheckinTimeHelper.dual_unit_or_query(query_start_time, query_end_time) }
      ]
    else
      query['uid'] = { '$in' => permitted_query_uids }
    end

    query
  end

  def serialized_checkins(checkins)
    return checkins if privileged_access?

    checkins.map { |checkin| redact_uid(checkin) }
  end

  def redact_uid(record)
    attributes = record.respond_to?(:attributes) ? record.attributes : record
    attributes = attributes.as_json if attributes.respond_to?(:as_json)
    attributes = attributes.to_h if attributes.respond_to?(:to_h)
    attributes = attributes.dup

    uid_key = attributes.key?('uid') ? 'uid' : :uid
    attributes[uid_key] = attributes[uid_key].to_s.hash if attributes.key?(uid_key)
    attributes
  end

  def permitted_query_uids
    @permitted_query_uids ||= begin
      return query_uids if privileged_access?

      member_card_uids = current_member.access_cards.map { |card| card.uid.to_s }
      query_uids & member_card_uids
    end
  end

  def privileged_access?
    is_privileged?
  end

  def query_uids
    @query_uids ||= begin
      parsed = JSON.parse(params.require(:uids))
      raise Error::UnprocessableEntity.new('uids must be an array') unless parsed.is_a?(Array)
      parsed.map(&:to_s)
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
