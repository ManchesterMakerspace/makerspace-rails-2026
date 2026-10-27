class Admin::AuditLogsController < AdminController
  include FastQuery::MongoidQuery

  def index
    logs = AuditLog.in_category(params[:category])

    logs = logs.where(log_type: params[:log_type])           if params[:log_type].present?
    logs = logs.where(event_type: params[:event_type])       if params[:event_type].present?
    logs = logs.where(actor_id: params[:actor_id])           if params[:actor_id].present?
    logs = logs.where(subject_id: params[:subject_id])       if params[:subject_id].present?
    logs = logs.where(:created_at.gte => Time.parse(params[:from_date])) if params[:from_date].present?
    logs = logs.where(:created_at.lte => Time.parse(params[:to_date]))   if params[:to_date].present?

    logs = logs.order_by(created_at: :desc)

    # Paginate the already-ordered/filtered set ourselves rather than via
    # query_resource -- that helper's own order_query would override the
    # created_at:desc ordering above with its column-sort default.
    @total_items = logs.count
    logs = paginate_resource(logs, query_params[:page_num])

    render_with_total_items(logs, { each_serializer: AuditLogSerializer, adapter: :attributes })
  end

  # The filter choices for the audit log screen: the categories, and the event
  # types that actually occur in the log (so the Event list cannot go stale).
  def filters
    categories = [{ value: AuditLog::ALL_EXCEPT_SLACK, label: 'All except Slack messages' },
                  { value: AuditLog::ALL, label: 'All' }] +
                 AuditLog::CATEGORIES.map { |key, rule| { value: key, label: rule[:label] } } +
                 [{ value: AuditLog::OTHER_CATEGORY, label: 'Other' }]
    event_types = AuditLog.distinct(:event_type).compact.sort.map do |event_type|
      { value: event_type, category: AuditLog.category_for(event_type) }
    end
    render json: { categories: categories, eventTypes: event_types }
  end

  private

  def authorized?
    raise ::Error::Forbidden.new unless is_admin? || is_board_member?
  end
end
