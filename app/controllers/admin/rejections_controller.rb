class Admin::RejectionsController < AuthenticationController
  before_action :authenticate_member!
  before_action :authorize_rejection_access

  def index
    rejections = RejectionCard.where(rejections_query).map(&:attributes)
    render json: { rejections: rejections } and return
  end

  private

  def authorize_rejection_access
    # Admins can see all rejection cards
    # Members can only see their own rejection cards
    return if is_admin?
    
    # Non-admin members can only query their own card
    parsed = JSON.parse(params.require(:uids))
    raise Error::UnprocessableEntity.new('uids must be an array') unless parsed.is_a?(Array)
    
    member_cards = current_member.access_cards.map(&:uid)
    requested_uids = parsed.map(&:to_s)
    
    unless requested_uids.all? { |uid| member_cards.include?(uid) }
      Rails.logger.warn("Non-admin member #{current_member.id} attempted to view rejection cards they don't own")
      raise Error::Forbidden.new
    end
  end

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
