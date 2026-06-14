class Admin::RejectionsController < AuthenticationController
  before_action :authenticate_member!
  before_action :authorize_rejection_access

  def index
    rejections = mask_uids(RejectionCard.where(rejections_query).map(&:attributes))
    render json: { rejections: rejections } and return
  end

  private

  def authorize_rejection_access
    # Admins can see all rejection cards
    # Members can only see their own rejection cards
    return if is_admin? || is_resource_manager? || is_board_member?

    # Regular members may only see their own cards. Ignore requested UIDs instead
    # of rejecting so callers cannot probe other members' cards.
    params.delete(:uids)
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
