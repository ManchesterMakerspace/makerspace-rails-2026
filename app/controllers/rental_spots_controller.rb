require "set"

class RentalSpotsController < AuthenticationController
  include FastQuery::MongoidQuery

  skip_before_action :authenticate_member!, :authenticated?, only: [:public_show]

  def index
    result = MongoCache.fetch(
      "rental_spots/#{cache_variant}",
      dependencies: ["rental_spots", "rentals", "rental_types", "invoice_options"]
    ) do
      criteria = RentalSpot.where(active: true)
      if params[:rental_type_id].present?
        criteria = criteria.where(rental_type_id: params[:rental_type_id])
      end

      records = if params[:available] == "true"
        all_records = criteria.to_a
        availability = availability_for(all_records)
        available_records = all_records.select { |spot| availability[spot.number] }
        @total_items = available_records.length
        page = (params[:page_num].presence || params[:pageNum]).to_i
        available_records.slice(
          [page, 0].max * FastQuery::ITEMS_PER_PAGE,
          FastQuery::ITEMS_PER_PAGE
        ) || []
      else
        query_resource(criteria).to_a
      end

      {
        "items" => serialize_spots(records),
        "total" => @total_items || records.length
      }
    end

    response.set_header("total-items", result["total"])
    render json: result["items"]
  end

  def show
    spot = find_rental_spot(params[:id])
    render json: spot, serializer: RentalSpotSerializer, adapter: :attributes
  end

  def public_show
    spot = find_rental_spot(params[:id])
    render json: spot, serializer: RentalSpotPublicSerializer, adapter: :attributes
  end

  private

  def cache_variant
    [
      "type=#{params[:rental_type_id]}",
      "available=#{params[:available]}",
      "page=#{params[:page_num].presence || params[:pageNum]}",
      "search=#{params[:search]}",
      "order_by=#{params[:order_by].presence || params[:orderBy]}",
      "order=#{params[:order]}"
    ].join("/")
  end

  def serialize_spots(spots)
    rental_type_ids = spots.map(&:rental_type_id).compact.uniq
    rental_types = RentalType.where(:id.in => rental_type_ids).to_a
      .index_by { |type| type.id.to_s }
    invoice_option_ids = rental_types.values.map(&:invoice_option_id).compact.uniq
    invoice_options = InvoiceOption.where(:id.in => invoice_option_ids).to_a
      .index_by { |option| option.id.to_s }

    ActiveModelSerializers::SerializableResource.new(
      spots,
      each_serializer: RentalSpotSerializer,
      adapter: :attributes,
      availability_by_number: availability_for(spots),
      rental_types_by_id: rental_types,
      invoice_options_by_id: invoice_options
    ).as_json
  end

  def availability_for(spots)
    numbers = spots.map(&:number)
    parents = spots.map(&:parent_number).compact
    child_numbers = RentalSpot.where(:parent_number.in => numbers).pluck(:number).to_a
    rented = Rental.where(
      :number.in => (numbers + parents + child_numbers).uniq,
      :status.in => %w[active pending]
    ).pluck(:number).to_a.to_set
    children_by_parent = RentalSpot.where(:parent_number.in => numbers)
      .only(:number, :parent_number)
      .to_a
      .group_by(&:parent_number)

    spots.to_h do |spot|
      children_rented = Array(children_by_parent[spot.number]).any? do |child|
        rented.include?(child.number)
      end
      available = spot.active? &&
        !rented.include?(spot.number) &&
        (spot.parent_number.blank? || !rented.include?(spot.parent_number)) &&
        !children_rented
      [spot.number, available]
    end
  end

  def find_rental_spot(identifier)
    spot = BSON::ObjectId.legal?(identifier) ? RentalSpot.where(id: identifier).first : nil
    spot ||= RentalSpot.find_by(number: identifier)
    raise Mongoid::Errors::DocumentNotFound.new(RentalSpot, { id: identifier }) if spot.nil?

    spot
  end
end
