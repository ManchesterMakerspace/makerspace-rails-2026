class ShopSerializer < ActiveModel::Serializer
  attribute :resource_managers do
    Member.where(:role.in => %w[resource_manager admin board_member], resource_manager_shop_ids: object.id.to_s).map { |m| { id: m.id.to_s, name: m.fullname } }
  end
  attributes :id, :name, :wiki_url, :gdrive_id, :slack_channel, :disabled, :reservable,
             :max_concurrent_reservations, :reservation_horizon_days,
             :minimum_advance_notice_hours, :prohibit_same_day_reservations, :reservation_full_day, :duration_fees, :max_reservation_duration_hours, :reservation_requires_approval,
             :reservation_prerequisite_tool_ids, :reservation_prerequisite_names,
             :color_id, :google_resource_id, :resource_email, :floor_name, :capacity

  attribute :tool_count do
    object.tools.count
  end

  attribute :wiki_url_override do
    object.wiki_url
  end

  def wiki_url
    object.effective_wiki_url
  end

  def reservable
    return false if scope&.status == 'pending'

    object.reservable
  end

  def reservation_prerequisite_names
    object.reservation_prerequisites.map(&:name)
  end
end
