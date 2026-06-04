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

    # Build time range — support both timeOf (current) and legacy time field
    if query_start_time || query_end_time
      time_range = {}
      time_range['$gte'] = query_start_time if query_start_time
      time_range['$lte'] = query_end_time   if query_end_time

      # Use $and to safely combine uid filter with $or time field conditions
      query['$and'] = [
        { 'uid' => { '$in' => query_uids } },
        {
          '$or' => [
            { 'timeOf' => time_range },
            { 'time'   => time_range }
          ]
        }
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
