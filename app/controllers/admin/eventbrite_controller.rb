class Admin::EventbriteController < AdminOrRmController
  MODELS = { 'events' => EventbriteEvent, 'orders' => EventbriteOrder, 'attendees' => EventbriteAttendee }.freeze
  def index
    scope = filtered
    response.set_header('total-items', scope.count)
    records = scope.order_by(created_at: :desc, id: :desc).skip([(params[:page_num] || params[:pageNum]).to_i, 0].max * 50).limit(50)
    render json: records.map { |record| EventbriteIntegration::Presenter.call(record) }, adapter: :attributes
  end
  def show
    record = base.find(params[:id])
    result = EventbriteIntegration::Presenter.call(record)
    if record.is_a?(EventbriteEvent)
      result['ticketClasses'] = EventbriteTicketClass.where(organization_id: record.organization_id, event_id: record.eventbrite_id).map { |r| EventbriteIntegration::Presenter.call(r) }
    elsif record.is_a?(EventbriteOrder)
      result['attendees'] = EventbriteAttendee.where(organization_id: record.organization_id, order_id: record.eventbrite_id).map { |r| EventbriteIntegration::Presenter.call(r) }
    end
    render json: result
  end
  private
  def base
    MODELS.fetch(params[:kind]).where(:organization_id.in => EventbriteIntegration::Configuration.organization_ids)
  end
  def filtered
    scope = base
    if params[:organization_id].present? && !EventbriteIntegration::Configuration.organization_ids.include?(params[:organization_id])
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
    member_id = params[:member_id].presence
    Member.find(member_id) if member_id
    if params[:kind] == 'attendees'
      scope = scope.where(member_id: member_id) if member_id
      scope = scope.where(member_id: nil) if params[:linked] == 'unlinked'
      scope = scope.where(:member_id.ne => nil) if params[:linked] == 'linked'
      scope = scope.where(link_conflict: true) if params[:linked] == 'conflict'
    elsif params[:kind] == 'orders' && (member_id || params[:linked].present?)
      attendees = EventbriteAttendee.where(:organization_id.in => EventbriteIntegration::Configuration.organization_ids)
      attendees = attendees.where(member_id: member_id) if member_id
      attendees = attendees.where(:member_id.ne => nil) unless params[:linked] == 'conflict'
      attendees = attendees.where(link_conflict: true) if params[:linked] == 'conflict'
      pairs = attendees.pluck(:organization_id, :order_id).uniq.map { |org, id| { organization_id: org, eventbrite_id: id } }
      scope = if params[:linked] == 'unlinked'
        pairs.empty? ? scope : scope.where('$nor' => pairs)
      else
        pairs.empty? ? scope.none : scope.where('$and' => [{ '$or' => pairs }])
      end
    end
    scope
  end
end
