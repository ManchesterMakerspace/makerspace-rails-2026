class ShopSerializer < ActiveModel::Serializer
  attributes :id, :name, :slack_channel, :disabled, :reservable,
             :max_concurrent_reservations, :reservation_horizon_days,
             :max_reservation_duration_hours, :reservation_requires_approval,
             :reservation_prerequisite_tool_ids

  attribute :tool_count do
    object.tools.count
  end
end
