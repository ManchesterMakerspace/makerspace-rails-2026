class Admin::EventbriteController < AdminOrRmController
  MODELS = { 'events' => EventbriteEvent, 'orders' => EventbriteOrder, 'attendees' => EventbriteAttendee }.freeze
  def index
    scope = filtered
    offset = [(params[:page_num] || params[:pageNum]).to_i, 0].max * 50
    filter = @member_id ? {} : EventbriteIntegration::HistoryQuery.event_filter(params)
    query = if params[:kind] == 'orders' && (@member_id || params[:linked].present?)
      EventbriteIntegration::OrderHistoryQuery.new(scope, member_id: @member_id, linked: params[:linked], event_filter: filter)
    else
      EventbriteIntegration::HistoryQuery.new(scope, event_filter: filter)
    end
    response.set_header('total-items', query.count)
    records = query.page(offset: offset, limit: 50)
    render json: EventbriteIntegration::Presenter.many(records), adapter: :attributes
  rescue EventbriteIntegration::HistoryQuery::InvalidFilter => e
    render json: { error: e.message }, status: :bad_request
  end
  def show
    record = base.only(*EventbriteIntegration::Presenter::FIELDS).find(params[:id])
    children = []
    if record.is_a?(EventbriteEvent)
      children = EventbriteTicketClass.where(organization_id: record.organization_id, event_id: record.eventbrite_id)
        .only(*EventbriteIntegration::Presenter::FIELDS)
    elsif record.is_a?(EventbriteOrder)
      children = EventbriteAttendee.where(organization_id: record.organization_id, order_id: record.eventbrite_id)
        .only(*EventbriteIntegration::Presenter::FIELDS)
    end
    result, *presented_children = EventbriteIntegration::Presenter.many([record] + children.to_a)
    result['ticketClasses'] = presented_children if record.is_a?(EventbriteEvent)
    result['attendees'] = presented_children if record.is_a?(EventbriteOrder)
    render json: result
  end
  private
  def base
    EventbriteIntegration::Configuration.scope_organizations(MODELS.fetch(params[:kind]).all)
  end
  def filtered
    scope = base
    if params[:organization_id].present? && !EventbriteIntegration::Configuration.organization_allowed?(params[:organization_id])
      raise Error::Forbidden.new
    end
    %w[organization_id event_id status].each do |key|
      next if params[key].blank? || (key == 'event_id' && params[:kind] == 'events')
      scope = scope.where(key => params[key])
    end
    if params[:search].present?
      regex = /#{Regexp.escape(params[:search].to_s[0, 100])}/i
      scope = scope.where('$or' => [{ name: regex }, { email: regex }])
    end
    if params[:member_id].present?
      Member.find(params[:member_id])
      # Finding an absent member returns nil in this application's Mongoid
      # configuration. Keep its requested ID as a filter, cast as Mongoid does
      # for attendee criteria, rather than accidentally returning global history.
      @member_id = EventbriteAttendee.where(member_id: params[:member_id]).selector.fetch('member_id')
    end
    if params[:kind] == 'attendees'
      scope = scope.where(member_id: @member_id) if @member_id
      scope = scope.where(member_id: nil) if params[:linked] == 'unlinked'
      scope = scope.where(:member_id.ne => nil) if params[:linked] == 'linked'
      scope = scope.where(link_conflict: true) if params[:linked] == 'conflict'
    end
    scope
  end
end
