module Service
  # Soft-deletes ("ghosts") a duplicate/abandoned Member account -- e.g. a
  # member who couldn't access their original account/email and signed up a
  # second time. The record is never destroyed: history (invoices, audit
  # log, etc.) keeps resolving, but it's excluded from normal queries via
  # Member's default_scope and its email frees up for reuse. Never sends any
  # notification to the member -- this is an internal cleanup action, and
  # ApplicationMailer drops any mail addressed to a soft-deleted member.
  #
  # This is NOT how you revoke a member's access. Revocation is done by
  # changing the `status` field on their member profile page (e.g. to
  # "revoked"), which blocks their email from being reused for a new
  # signup -- the opposite of what soft-delete does. Soft-delete is only for
  # cleaning up a duplicate/abandoned account, and refuses to run at all on
  # a member with an active, unexpired membership or a live subscription
  # (see Member#eligible_for_soft_delete?), or on a member with an open
  # invoice (see .open_invoice_count), so it can't be used as a shortcut for
  # revocation even by mistake.
  #
  # Deleting also removes the member from Slack and from the Google Drive
  # folders the portal manages. If a removal fails (or could not be attempted
  # for someone who has Slack or Drive access), the delete stops with
  # ManualRemovalRequiredError so the account stays visible and can be retried.
  # An admin who has removed them by hand can confirm with
  # manual_removal_confirmed: true to finish; that is written to the audit log.
  # The status becomes "inactive" so their cards go invalid and anything that
  # keys off status treats them as a non-member (revoked and suspended are kept,
  # since those are deliberate blocks).
  module MemberSoftDelete
    class ActiveMembershipError < StandardError; end
    class AlreadyDeletedError < StandardError; end
    class NotDeletedError < StandardError; end

    class OpenInvoicesError < StandardError
      attr_reader :count

      def initialize(message, count:)
        super(message)
        @count = count
      end
    end

    class ManualRemovalRequiredError < StandardError
      attr_reader :problems

      def initialize(message, problems:)
        super(message)
        @problems = problems
      end
    end

    DRIVE_LABELS = { gdrive_resources: 'Resources folder', gdrive_transfer_share: 'Transfer Share folder' }.freeze
    KEPT_STATUSES = %w[revoked suspended].freeze

    # Invoices that are still open: not settled and not refunded. That is a bill nobody has paid, and also a
    # payment that is held because the member has no fob yet -- a held payment means a current paying member.
    def self.open_invoice_count(member)
      Invoice.where(settled_at: nil, :refunded.ne => true)
             .any_of({ member_id: member.id }, { resource_id: member.id.to_s })
             .count
    end

    def self.delete!(member, actor:, manual_removal_confirmed: false)
      raise AlreadyDeletedError, "#{member.fullname} is already deleted" if member.merged_at.present?
      unless member.eligible_for_soft_delete?
        raise ActiveMembershipError,
          "#{member.fullname} has an active, unexpired membership or a live subscription and cannot be deleted"
      end

      open_count = open_invoice_count(member)
      if open_count.positive?
        raise OpenInvoicesError.new(
          "#{member.fullname} has #{open_count} open invoice#{'s' unless open_count == 1} (unpaid, or paid but not yet " \
          "applied) and cannot be deleted. Settle, refund or cancel #{open_count == 1 ? 'it' : 'them'} first.",
          count: open_count
        )
      end

      before = member.attributes.dup

      results = Service::MemberAccess.full_deprovision(member, alert: false) || {}
      problems = removal_problems(member, results)
      if problems.any? && !manual_removal_confirmed
        raise ManualRemovalRequiredError.new(
          "#{member.fullname} was not removed from everything automatically: #{problems.join('; ')}. Remove them " \
          "yourself, then confirm that you did to finish deleting the account.",
          problems: problems
        )
      end

      member.update_attribute(:status, 'inactive') unless KEPT_STATUSES.include?(member.status)
      member.update_attribute(:merged_at, Time.current)

      details = "#{actor&.fullname || 'An admin'} marked #{member.fullname} (#{member.email}) as deleted. #{removal_summary(results)}"
      details += " #{actor&.fullname || 'The admin'} confirmed removing them by hand: #{problems.join('; ')}." if problems.any?

      Service::AuditLogger.log(
        log_type:        'member',
        event_type:      'member_soft_deleted',
        resource_type:   'Member',
        resource_id:     member.id,
        actor:           actor,
        subject:         member,
        before_snapshot: before,
        after_snapshot:  member.attributes,
        message_details: details,
        slack_channel:   ::Service::SlackConnector.logs_channel
      )

      member
    end

    def self.restore!(member, actor:)
      raise NotDeletedError, "#{member.fullname} is not deleted" if member.merged_at.blank?

      before = member.attributes.dup
      member.update_attribute(:merged_at, nil)

      Service::AuditLogger.log(
        log_type:        'member',
        event_type:      'member_restored',
        resource_type:   'Member',
        resource_id:     member.id,
        actor:           actor,
        subject:         member,
        before_snapshot: before,
        after_snapshot:  member.attributes,
        message_details: "#{actor&.fullname || 'An admin'} restored #{member.fullname}'s (#{member.email}) account.",
        slack_channel:   ::Service::SlackConnector.logs_channel
      )

      member
    end

    # What still has to be removed by hand. A removal that errored always counts. One that was skipped (the
    # setting that allows it is off) counts only when the member actually has that access, because with no Slack
    # or Drive access there is nothing to remove.
    def self.removal_problems(member, results)
      problems = []

      slack = results[:slack]
      if slack
        if slack[:status] == :error
          problems << "Slack: #{slack[:message]}"
        elsif slack[:status] == :skipped && member.slack_user&.slack_id.present?
          problems << "Slack: #{slack[:reason]}"
        end
      end

      has_drive_access = member.google_resources_access_confirmed_at.present? || member.google_transfer_access_confirmed_at.present?
      DRIVE_LABELS.each do |key, label|
        drive = results[key]
        next unless drive

        if drive[:status] == :error
          problems << "Google Drive (#{label}): #{drive[:message]}"
        elsif drive[:status] == :skipped && has_drive_access
          problems << "Google Drive (#{label}): #{drive[:reason]}"
        end
      end

      problems << "Access removal: #{results[:revoke][:message]}" if results[:revoke]
      problems
    end

    def self.removal_summary(results)
      parts = []
      parts << "Slack: #{results.dig(:slack, :status) || 'not attempted'}."
      drive = DRIVE_LABELS.keys.map { |key| results.dig(key, :status) }.compact
      parts << "Google Drive: #{drive.empty? ? 'not attempted' : drive.uniq.join('/')}."
      parts.join(' ')
    end
  end
end
