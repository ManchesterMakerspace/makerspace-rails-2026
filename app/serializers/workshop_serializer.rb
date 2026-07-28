class WorkshopSerializer < ActiveModel::Serializer
  attributes :id, :name, :wiki_url, :slack_channel, :disabled,
             :reservable, :reservations_available, :resource_managers, :tools

  def wiki_url
    object.effective_wiki_url
  end

  def tools
    visible_tools.map do |tool|
      {
        id: tool.id.to_s,
        name: tool.name,
        wikiUrl: tool.effective_wiki_url,
        description: tool.description,
        disabled: tool.disabled?,
        reservable: tool.reservable
      }
    end
  end

  def resource_managers
    Member.where(
      role: "resource_manager",
      :resource_manager_shop_ids.in => [object.id.to_s]
    ).order_by(lastname: :asc, firstname: :asc).map do |member|
      slack_user = member.slack_user
      {
        id: member.id.to_s,
        name: member.fullname,
        slackUrl: slack_user &&
          ::Service::SlackConnector.slack_user_url(slack_user.slack_id)
      }
    end
  end

  def reservations_available
    return false unless viewer_can_reserve?
    return false if object.disabled?
    return true if object.reservable &&
      reservation_requirements_met?(object.reservation_prerequisite_tool_ids)

    visible_tools.any? do |tool|
      !tool.disabled? && tool.reservable &&
        reservation_requirements_met?(tool.effective_reservation_prerequisite_ids)
    end
  end

  private

  def viewer
    scope
  end

  def visible_tools
    @visible_tools ||= begin
      tools = object.tools.order_by(name: :asc).to_a
      if viewer.role.in?(%w[admin board_member]) || viewer.manages_shop?(object)
        tools
      else
        tools.select do |tool|
          !tool.disabled? || checked_out_tool_ids.include?(tool.id.to_s)
        end
      end
    end
  end

  def viewer_can_reserve?
    viewer.role == "board_member" || viewer.active_unexpired?
  end

  def reservation_requirements_met?(required_ids)
    return true if viewer.role == "board_member"

    (Array(required_ids).map(&:to_s) - checked_out_tool_ids).empty?
  end

  def checked_out_tool_ids
    @checked_out_tool_ids ||= ToolCheckout.where(
      member_id: viewer.id,
      revoked_at: nil
    ).pluck(:tool_id).map(&:to_s)
  end
end
