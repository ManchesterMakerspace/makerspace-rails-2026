class ToolGroupCheckout
  def self.authorized?(actor, group)
    actor && group && !group.disabled? && SlackCheckoutModal.membership_error(actor).nil? &&
      (ToolGroup.manageable_by?(actor, group.shop_id) ||
        (actor.valid_for_checkout_request? && CheckoutApprover.find_by(member_id: actor.id)&.can_approve_group?(group))) &&
      group.included_tools.all? { |tool| actor.status != 'pending' || tool.allow_pending }
  end

  def self.review(member:, group:, requesting: false)
    raise Error::UnprocessableEntity.new('Group unavailable') if group.disabled?
    raise Error::UnprocessableEntity.new('This group does not accept requests') if requesting && !group.requestable?
    tools = group.included_tools
    records = ToolCheckout.where(member_id: member.id).to_a
    active = records.select(&:active?).map { |row| row.tool_id.to_s }
    revoked = records.reject(&:active?).map { |row| row.tool_id.to_s }
    raise Error::UnprocessableEntity.new('A checkout in this group has been revoked') if (revoked & group.included_tool_ids).any?
    tools.each do |tool|
      raise Error::UnprocessableEntity.new('An included tool is unavailable') if tool.disabled?
      eligible = member.status == 'pending' ? tool.allow_pending : member.status == 'activeMember' && member.active_unexpired?
      raise Error::UnprocessableEntity.new('Membership is not eligible for every included tool') unless eligible
    end
    required = (group.prerequisite_ids + tools.flat_map(&:prerequisite_ids)).map(&:to_s).uniq - group.included_tool_ids
    missing = required - active
    {
      revision: group.revision, included_tool_ids: group.included_tool_ids,
      held_tool_ids: group.included_tool_ids & active,
      create_tool_ids: group.included_tool_ids - active,
      prerequisite_ids: required, missing_prerequisite_ids: missing
    }
  end

  def self.with_tool_locks(member_id, ids, &block)
    ordered = ids.map(&:to_s).uniq.sort
    return yield if ordered.empty?
    CheckoutMutationLock.with(member_id: member_id, tool_id: ordered.first) do
      with_tool_locks(member_id, ordered.drop(1), &block)
    end
  end

  def self.request!(member:, group:, note: nil)
    request = CatalogMutationLock.with([group.shop_id]) do
      group.reload
      with_tool_locks(member.id, group.included_tool_ids) do
        member.reload
        review = review(member: member, group: group, requesting: true)
        validate_review!(review)
        if ToolCheckoutRequest.where(member_id: member.id, tool_group_id: group.id, status: 'open').exists?
          raise Error::UnprocessableEntity.new('An open request already exists for this group')
        end
        ToolCheckoutRequest.create!(member: member, tool_group: group, note: note)
      end
    end
    CheckoutCreation.notify { request.announce_request }
    CheckoutCreation.notify { request.notify_requestor }
    request
  end

  def self.approve!(actor:, member:, group:, revision:, source: 'portal', request_id: nil)
    result = CatalogMutationLock.with([group.shop_id]) do
      CheckoutApproverMutationLock.with(member_id: actor.id) do
        group.reload
        with_tool_locks(member.id, group.included_tool_ids) do
          ToolCheckout.with_session do |session|
            session.with_transaction do
              yield if block_given?
              actor.reload
              member.reload
              group.reload
              raise Error::Forbidden.new('You cannot approve this group') unless authorized?(actor, group)
              raise Error::Conflict.new('This group changed. Refresh the review before approving.') unless group.revision == revision.to_i
              if request_id
                request = ToolCheckoutRequest.find_by(id: request_id)
                unless request&.open? && request.tool_group_id == group.id && request.member_id == member.id
                  raise Error::UnprocessableEntity.new('This checkout request is no longer open')
                end
              end
              review = review(member: member, group: group)
              raise Error::UnprocessableEntity.new('Complete prerequisite checkouts first') if review[:missing_prerequisite_ids].any?
              # A retry after successful approval returns the original physical records;
              # no additional checkout or credit is created.
              existing = ToolCheckout.where(member_id: member.id, :tool_id.in => review[:held_tool_ids], revoked_at: nil).to_a
              batch_id = SecureRandom.uuid
              created = review[:create_tool_ids].map do |tool_id|
                ToolCheckout.create!(member: member, tool_id: tool_id, approved_by: actor,
                  signed_off_via: source, group_id: group.id, group_revision: group.revision,
                  group_name: group.name, approval_batch_id: batch_id,
                  defer_users_channel_invitation: true, defer_group_callbacks: true)
              end
              if created.any?
                credit = CheckoutApproverCredit.award!(created.first)
                created.drop(1).each { |checkout| checkout.set(volunteer_credit_id: credit.id) } if credit
              end
              reconciled = reconcile!(member.id)
              { checkouts: created, skipped: existing,
                reconciled: reconciled,
                approval_batch_id: created.any? ? batch_id : existing.map(&:approval_batch_id).compact.uniq.one? ? existing.find(&:approval_batch_id).approval_batch_id : nil }
            end
          ensure
            session.end_session
          end
        end
      end
    end
    notify(group, member, result) if result[:checkouts].any?
    Array(result[:reconciled]).reject { |request| request.tool_group_id == group.id }.each do |request|
      CheckoutCreation.notify { request.refresh_closed_announcement }
    end
    result
  end

  def self.validate_review!(review)
    raise Error::UnprocessableEntity.new('Complete prerequisite checkouts first') if review[:missing_prerequisite_ids].any?
    raise Error::UnprocessableEntity.new('Every included tool already has an active checkout') if review[:create_tool_ids].empty?
  end

  def self.reconcile!(member_id)
    active = ToolCheckout.where(member_id: member_id, revoked_at: nil).pluck(:tool_id).map(&:to_s)
    ToolCheckoutRequest.where(member_id: member_id, status: 'open').filter_map do |request|
      required = request.tool_group ? request.tool_group.included_tool_ids : [request.tool_id.to_s]
      next unless required.present? && (required - active).empty?
      checkout = ToolCheckout.where(member_id: member_id, :tool_id.in => required, revoked_at: nil).first
      request.update!(status: 'closed', checked_out_id: checkout.id)
      request
    end
  end

  def self.notify(group, member, result)
    created = result[:checkouts]
    CheckoutCreation.notify do
      Service::AuditLogger.log(log_type: 'member', event_type: 'tool_group_checkout_created',
        resource_type: 'ToolGroup', resource_id: group.id, actor: created.first.approved_by, subject: member,
        after_snapshot: { approval_batch_id: result[:approval_batch_id], group_revision: group.revision,
          checkout_ids: created.map { |row| row.id.to_s }, included_tool_ids: group.included_tool_ids })
    end
    created.uniq { |row| row.tool.users_channel }.each do |checkout|
      CheckoutCreation.notify { checkout.invite_member_to_users_channel }
    end
    CheckoutCreation.notify { ToolCheckoutSlackCanvasSyncJob.perform_later(group.shop_id.to_s) }
    message = "*#{member.fullname}* has been checked out on *#{group.name}*: #{created.map { |row| row.tool.name }.join(', ')}."
    channels = created.map { |row| row.tool.users_channel.presence }.compact
    channel = group.announce? ? (group.announce_channel.presence || group.shop.slack_channel) : nil
    channels << channel if channel.present?
    request = ToolCheckoutRequest.where(member_id: member.id, tool_group_id: group.id, status: 'closed').order_by(request_date: :desc).first
    channels.uniq.each do |destination|
      CheckoutCreation.notify do
        if destination == channel && request&.message_id.present?
          Service::SlackConnector.update_slack_message(destination, request.message_id, message)
        else
          response = Service::SlackConnector.send_slack_message(message, destination)
          request.register_announcement(response.ts) if destination == channel && request && response.respond_to?(:ts)
        end
      end
    end
    CheckoutCreation.notify do
      slack_id = member.slack_user&.slack_id
      if slack_id.present? && !member.direct_notifications_suppressed?
        details = group.included_tools.map do |tool|
          [tool.name, tool.effective_wiki_url, tool.gdrive_id.present? ? "https://drive.google.com/drive/folders/#{tool.gdrive_id}" : nil,
            tool.effective_requestor_annotation, tool.notes_visible_to?(member) ? tool.notes : nil].compact.join("\n")
        end.join("\n\n")
        Service::SlackConnector.send_slack_message("#{message}\n\n#{details}", slack_id)
      end
    end
  end
end
