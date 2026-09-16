class ToolCheckoutSerializer < ActiveModel::Serializer
  attribute :out_of_service do
    !!object.tool&.out_of_service
  end
  attributes :id, :member_id, :tool_id, :checked_out_at, :revoked_at,
             :revocation_reason, :signed_off_via, :approved_by_id

  attribute :tool_name do
    object.tool.try(:name)
  end

  attribute :shop_name do
    object.tool.try(:shop).try(:name)
  end

  attribute :shop_id do
    object.tool.try(:shop_id)
  end

  attribute :shop_wiki_url do
    object.tool.try(:shop).try(:effective_wiki_url)
  end

  attribute :member_name do
    object.member.try(:fullname)
  end

  attribute :member_email do
    object.member.try(:email)
  end

  attribute :approved_by_name do
    object.approved_by.try(:fullname)
  end

  attribute :active do
    object.active?
  end

  # Sensitive (e.g. lock combo) -- only present when the viewer is entitled
  # per Tool#notes_visible_to? (an active, approved checkout holder, a
  # checkout approver for the tool, or a privileged member). An open,
  # not-yet-approved request or a revoked checkout does not qualify.
  attribute :tool_notes, if: :tool_notes_visible? do
    object.tool.notes
  end

  def tool_notes_visible?
    object.tool.present? && object.tool.notes_visible_to?(scope)
  end
end
