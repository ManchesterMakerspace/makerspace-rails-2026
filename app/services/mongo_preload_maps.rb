class MongoPreloadMaps
  def self.for_tool_records(records)
    tool_ids = records.map(&:tool_id).compact.uniq
    member_ids = records.flat_map do |record|
      [record.try(:member_id), record.try(:approved_by_id), record.try(:decided_by_id)]
    end.compact.uniq
    tools = Tool.where(:id.in => tool_ids).to_a.index_by { |tool| tool.id.to_s }
    shop_ids = tools.values.map(&:shop_id).compact.uniq

    {
      members_by_id: Member.where(:id.in => member_ids).to_a.index_by { |member| member.id.to_s },
      tools_by_id: tools,
      shops_by_id: Shop.where(:id.in => shop_ids).to_a.index_by { |shop| shop.id.to_s },
      slack_users_by_member_id: SlackUser.where(:member_id.in => member_ids)
        .to_a.index_by { |user| user.member_id.to_s }
    }
  end

  def self.for_reservations(records)
    member_ids = records.flat_map { |record| [record.member_id, record.decided_by_id] }
      .compact.uniq
    tool_ids = records.flat_map { |record| Array(record.tool_ids) }.compact.uniq
    shop_ids = records.map(&:shop_id).compact.uniq

    {
      members_by_id: Member.where(:id.in => member_ids).to_a.index_by { |member| member.id.to_s },
      tools_by_id: Tool.where(:id.in => tool_ids).to_a.index_by { |tool| tool.id.to_s },
      shops_by_id: Shop.where(:id.in => shop_ids).to_a.index_by { |shop| shop.id.to_s }
    }
  end
end
