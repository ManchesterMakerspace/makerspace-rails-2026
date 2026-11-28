class PublicEventbriteEventsController < ActionController::Base
  def index
    events = EventbriteIntegration::PublicEvents.list(params)
    respond_to do |format|
      format.html do
        render :index, layout: 'public_catalog', locals: { events: events,
          page: { title: 'Eventbrite events · Manchester Makerspace', footer_links: PublicCatalog.footer_links } }
      end
      format.json { render json: events, adapter: :attributes }
      format.xml { render xml: events.to_xml(root: 'events', children: 'event', dasherize: false) }
    end
  rescue EventbriteIntegration::PublicEvents::InvalidFilter => e
    respond_to do |format|
      format.html { render plain: e.message, status: :bad_request }
      format.json { render json: { error: e.message }, status: :bad_request }
      format.xml { render xml: { message: e.message }.to_xml(root: 'error'), status: :bad_request }
    end
  end
end
