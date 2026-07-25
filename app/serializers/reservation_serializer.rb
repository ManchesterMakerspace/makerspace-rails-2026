class ReservationSerializer < ActiveModel::Serializer
  attributes :id, :title, :member_id, :member_name, :shop_id, :shop_name,
             :reservation_scope, :tool_ids, :tool_names, :start_at, :end_at,
             :status, :approval_reasons, :decision_note, :decided_by_id,
             :decided_by_name, :decided_at, :source, :calendar_event_id,
             :calendar_html_link, :calendar_sync_status, :calendar_synced_at,
             :created_at, :updated_at

  attribute :calendar_sync_error, if: :manager_view?

  def member_name
    member_for(object.member_id).try(:fullname)
  end

  def shop_name
    shop.try(:name)
  end

  def tool_names
    return object.tools.map(&:name) unless instance_options.key?(:tools_by_id)

    Array(object.tool_ids).filter_map do |tool_id|
      instance_options[:tools_by_id][tool_id.to_s]&.name
    end
  end

  def decided_by_name
    member_for(object.decided_by_id).try(:fullname)
  end

  def manager_view?
    return false unless scope
    scope.role.in?(%w[admin board_member]) || scope.manages_shop?(object.shop_id)
  end

  private

  def member_for(member_id)
    return nil if member_id.blank?
    return Member.find_by(id: member_id) unless instance_options.key?(:members_by_id)

    instance_options[:members_by_id][member_id.to_s]
  end

  def shop
    return object.shop unless instance_options.key?(:shops_by_id)

    instance_options[:shops_by_id][object.shop_id.to_s]
  end
end
