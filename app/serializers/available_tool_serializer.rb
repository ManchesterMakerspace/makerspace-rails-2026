class AvailableToolSerializer < ToolSerializer
  attributes :unmet_prerequisite_ids, :unmet_prerequisite_names, :requestable

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
