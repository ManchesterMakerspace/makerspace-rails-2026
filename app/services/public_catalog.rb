# Deliberately project only public fields. Never serialize a Mongoid document here.
class PublicCatalog
  class Unavailable < StandardError; end
  def self.shop(id)
    raise Unavailable unless BSON::ObjectId.legal?(id.to_s)
    record = Shop.where(id: id, :disabled.ne => true).only(:id, :name, :wiki_url, :out_of_service, :google_resource_id, :resource_email, :floor_name).first
    raise Unavailable unless record
    record
  end

  def self.tool(id, public_only: true)
    raise Unavailable unless BSON::ObjectId.legal?(id.to_s)
    query = Tool.where(id: id, :disabled.ne => true)
    query = query.only(:id, :name, :description, :wiki_url, :shop_id, :open, :out_of_service, :location_id, :google_resource_id, :resource_email) if public_only
    record = query.first
    raise Unavailable unless record
    [record, shop(record.shop_id)]
  end

  def self.shop_fields(shop)
    { id: shop.id.to_s, name: shop.name, wiki_url: safe_url(shop.effective_wiki_url), out_of_service: !!shop.out_of_service }
  end

  def self.tool_fields(tool, shop)
    { id: tool.id.to_s, name: tool.name, description: tool.description,
      open: tool.open, out_of_service: !!tool.out_of_service, wiki_url: safe_url(tool.wiki_url.presence || WikiUrlBuilder.tool_url(shop.name, tool.name)),
      shop: shop_fields(shop) }
  end

  FLOOR_PLAN_DIR = Rails.root.join("app/assets/images/shopFloorPlans")
  MAP_PADDING_PCT = 5.0
  MAP_MIN_SPAN_PCT = 12.0

  # Static map for the tool page: the shop's floor plan cropped to the shop,
  # with the shop's outline and this tool's storage spot. Plain numbers only
  # (floor-plan units), so it is safe to publish and to hash into the page's
  # cache key -- moving a marker changes the key and the next scan re-renders.
  # Never includes location names or any other shop's geometry.
  def self.tool_map(tool, shop)
    return unless tool.location_id
    locations = Location.where(shop_id: shop.id).only(:id, :parent_id, :x_pct, :y_pct, :shape_points, :floor_name).to_a
    by_id = locations.index_by(&:id)
    target = by_id[tool.location_id]
    return unless target

    # A shop can span floors, so the plan comes from the tool's own location.
    floor = (target.floor_name.presence || shop.floor_name).to_s
    size = floor_plan_size(floor)
    return unless size

    spot = nil
    node = target
    seen = Set.new
    while node && !spot && seen.add?(node.id)
      spot = location_geometry(node)
      node = by_id[node.parent_id]
    end
    return unless spot

    areas = locations.select { |l| l.parent_id.nil? && (l.floor_name.presence || shop.floor_name).to_s == floor }
      .filter_map { |l| location_geometry(l) }
    points = (areas + [spot]).flat_map { |g| g[:shape] || [g[:pin]] }
    min_x, max_x = widen(*points.map(&:first).minmax)
    min_y, max_y = widen(*points.map(&:last).minmax)

    w, h = size
    to_units = ->(pt) { [(pt[0] * w / 100.0).round(2), (pt[1] * h / 100.0).round(2)] }
    box = [min_x * w / 100.0, min_y * h / 100.0, (max_x - min_x) * w / 100.0, (max_y - min_y) * h / 100.0].map { |v| v.round(2) }
    marker = spot[:pin] || centroid(spot[:shape])
    { floor: floor, image_size: size, view_box: box,
      shop_areas: areas.filter_map { |g| g[:shape]&.map(&to_units) },
      tool_shape: spot[:shape]&.map(&to_units), tool_marker: to_units.call(marker),
      marker_radius: ([box[2], box[3]].min * 0.035).round(2) }
  end

  def self.location_geometry(location)
    points = Array(location.shape_points).filter_map do |pt|
      pt = pt.to_h.with_indifferent_access
      [pt[:x].to_f, pt[:y].to_f] if pt[:x] && pt[:y]
    end
    return { shape: points } if points.size >= 3
    { pin: [location.x_pct.to_f, location.y_pct.to_f] } if location.x_pct && location.y_pct
  end

  def self.centroid(points)
    [points.sum(&:first) / points.size, points.sum(&:last) / points.size]
  end

  def self.widen(min, max)
    min -= MAP_PADDING_PCT
    max += MAP_PADDING_PCT
    if max - min < MAP_MIN_SPAN_PCT
      mid = (min + max) / 2
      min, max = mid - MAP_MIN_SPAN_PCT / 2, mid + MAP_MIN_SPAN_PCT / 2
    end
    [[min, 0.0].max, [max, 100.0].min]
  end

  # [width, height] from the floor-plan SVG's viewBox, or nil when the floor
  # has no plan file. floor_name is validated to B/1/2; the format check
  # keeps the path safe regardless.
  def self.floor_plan_size(floor)
    return unless floor.match?(/\A[A-Za-z0-9]+\z/)
    @floor_plan_sizes ||= {}
    @floor_plan_sizes[floor] ||= begin
      path = FLOOR_PLAN_DIR.join("floor-#{floor}.svg")
      box = File.exist?(path) && File.read(path)[/viewBox="([^"]+)"/, 1]
      nums = box.to_s.split.map(&:to_f)
      nums.size == 4 && nums[2].positive? && nums[3].positive? ? [nums[2], nums[3]] : false
    end || nil
  end

  def self.calendar_fields(record)
    resource_id = record.google_resource_id.to_s.strip
    address = record.resource_email.to_s.strip
    if address.blank?
      return nil if resource_id.blank?

      # Legacy records may have only a calendar ID or full calendar address.
      address = resource_id.end_with?("@resource.calendar.google.com") ? resource_id : "#{resource_id}@resource.calendar.google.com"
    end
    { name: record.name, url: "https://calendar.google.com/calendar/embed?#{URI.encode_www_form(src: address)}" }
  end

  def self.footer_links
    [
      { label: "Public Home", icon: "home", url: "https://manchestermakerspace.org/" },
      { label: "Public Wiki", icon: "help_center", url: safe_url(WikiUrlBuilder.base_url) },
      { label: "Event Calendar", icon: "calendar_month", url: "https://manchestermakerspace.org/calendar" },
      { label: "Chat with us on Slack", icon: "chat", url: "https://manchestermakerspace.slack.com/archives/C29L2UMDF" },
      { label: "Contact us via Email", icon: "mail", url: "mailto:#{ENV.fetch('SMTP_FROM', 'contact@manchestermakerspace.org')}?subject=Member%20Portal%20assistance%20request" }
    ].select { |link| link[:url].present? }
  end

  def self.safe_url(value)
    uri = URI.parse(value.to_s)
    value if uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end
end
