class Admin::RejectionsController < AuthenticationController
  def index
    render json: RejectionCard.where(rejections_query), adapter: :attributes and return
  end

  private

  def rejections_query
    query = { :uid.in => query_uids }
    if query_start_time || query_end_time
      query[:timeOf] = {}
      query[:timeOf]['$gte'] = Time.at(query_start_time / 1000.0).utc if query_start_time
      query[:timeOf]['$lte'] = Time.at(query_end_time / 1000.0).utc if query_end_time
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
