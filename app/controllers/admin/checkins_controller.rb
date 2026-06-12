class Admin::CheckinsController < AuthenticationController
  def index
    checkins = checkins_collection.find(checkins_query).to_a
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
