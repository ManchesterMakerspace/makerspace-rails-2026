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
    query = { uid: { '$in' => query_uids } }
    if query_start_time || query_end_time
      query[:timeOf] = {}
      query[:timeOf]['$gte'] = query_start_time if query_start_time
      query[:timeOf]['$lte'] = query_end_time if query_end_time
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
