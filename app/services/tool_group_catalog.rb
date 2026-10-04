class ToolGroupCatalog
  def self.save!(actor:, attributes:, group: nil, revision: nil)
    shop_id = group&.shop_id || attributes[:shop_id]
    CatalogMutationLock.with([shop_id]) do
      actor.reload
      raise Error::Forbidden.new('You cannot manage this shop') unless ToolGroup.manageable_by?(actor, shop_id)
      group&.reload
      if group && group.revision != revision.to_i
        raise Error::Conflict.new('This group changed. Refresh before saving.')
      end
      # Lock before opening the snapshot, and retain locks until grants commit.
      member_ids = group ? CheckoutApprover.where(tool_group_ids: group.id.to_s).pluck(:member_id) : []
      with_approver_locks(member_ids.map(&:to_s).uniq.sort) do
        ToolGroup.with_session do |session|
          existing_id = group&.id
          session.with_transaction do
            group = existing_id ? ToolGroup.find(existing_id) : ToolGroup.new
            group.assign_attributes(attributes)
            group.revision += 1 if group.persisted?
            group.save!
            CheckoutApprover.where(tool_group_ids: group.id.to_s).each do |approver|
              if ToolCheckout.where(member_id: approver.member_id, :tool_id.in => group.included_tool_ids, :revoked_at.ne => nil).exists?
                approver.pull(tool_group_ids: group.id.to_s)
                next
              end
              CheckoutApprover.collection.find(_id: approver.id).update_one('$addToSet' => {
                'tool_ids' => { '$each' => group.included_tool_ids },
                'group_granted_tool_ids' => { '$each' => group.included_tool_ids }
              })
              approver.pull(tool_group_ids: group.id.to_s) if group.archived?
            end
            group.close_open_requests! if group.archived?
          end
        ensure
          session.end_session
        end
      end
      group
    end
  end

  def self.with_approver_locks(member_ids, &block)
    return yield if member_ids.empty?

    CheckoutApproverMutationLock.with(member_id: member_ids.first) do
      with_approver_locks(member_ids.drop(1), &block)
    end
  end
  private_class_method :with_approver_locks
end
