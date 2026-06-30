class AvailableToolSerializer < ActiveModel::Serializer
  attributes :id, :name, :description, :disabled, :announce, :announce_channel,
             :shop_id, :shop_name, :prerequisite_ids, :prerequisite_names,
             :unmet_prerequisite_ids, :unmet_prerequisite_names, :requestable

  attribute :shop_name do
    object.shop.try(:name)
  end

  attribute :prerequisite_names do
    object.prerequisites.map(&:name)
  end

  def unmet_prerequisite_ids
    object.respond_to?(:unmet_prerequisite_ids) ? object.unmet_prerequisite_ids : []
  end

  def unmet_prerequisite_names
    Tool.where(:id.in => unmet_prerequisite_ids).map(&:name)
  end

  def requestable
    unmet_prerequisite_ids.empty?
  end
end
