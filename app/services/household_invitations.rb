# A household primary inviting a second adult by email, and that adult accepting. The rules (see also Group):
#
#   * only the primary of a household plan can invite, once the household payment has been accepted (Group.payment_accepted_for?)
#   * the invitation holds one of the plan's seats until it is accepted, revoked or expires (14 days), so the household can
#     never hold more adults than the plan covers
#   * the invited person must be signed in with exactly the email the primary typed to accept
#   * nobody pays twice: someone with an active subscription, or with paid time that has not run out, cannot join until it
#     ends (an admin can still link them from Manage Household, which warns that their remaining time is replaced)
#   * the second adult's address must match the household's (Service::AddressMatch)
#
# The household itself is created when the first invitation is sent, so staff do not have to Create Household first.
module HouseholdInvitations
  EMAIL_PATTERN = URI::MailTo::EMAIL_REGEXP

  class << self
    # Whether this member can invite right now, and if not, why in plain words.
    # resending: an invitation already holds a seat, so a full household does not stop it being sent again.
    def eligibility(member, resending: false)
      return denied('Only the primary member of a household can invite someone.') if member.household_role == :secondary
      return denied('Your membership is not on a household plan.') unless household_plan_current?(member)
      unless Group.payment_accepted_for?(member)
        return denied('Your household payment has not been accepted yet. You can invite your second adult once it is.')
      end

      group = household_for(member)
      size = group ? group.size : Group.size_for(member)
      used = group ? group.seats_used : 1
      return denied("Your household is full (#{used} of #{size} adults).") if used >= size && !resending

      { allowed: true, reason: nil }
    end

    # What the member's household screen shows.
    def state_for(member)
      role = member.household_role
      group = household_for(member)
      eligibility = role == :secondary ? nil : eligibility(member)
      {
        role: role&.to_s,
        household_plan: role == :primary || household_plan_current?(member),
        can_invite: eligibility ? eligibility[:allowed] : false,
        invite_blocked_reason: eligibility && !eligibility[:allowed] ? eligibility[:reason] : nil,
        plan_size: role == :secondary ? nil : (group ? group.size : (household_plan_current?(member) ? Group.size_for(member) : nil)),
        household: group && household_summary(group, member, role),
        invited_to_a_household: role.nil? && HouseholdInvitation.outstanding.where(invited_email: member.email.to_s.downcase).exists?
      }
    end

    def invite!(primary:, email:)
      email = email.to_s.strip.downcase
      raise ::Error::UnprocessableEntity.new('Enter a valid email address.') unless email.match?(EMAIL_PATTERN)
      raise ::Error::UnprocessableEntity.new('That is your own email address.') if email == primary.email.to_s.downcase

      existing_group = household_for(primary)
      resending = !!(existing_group && group_invitations(existing_group).outstanding.where(invited_email: email).exists?)
      check = eligibility(primary, resending: resending)
      raise ::Error::UnprocessableEntity.new(check[:reason]) unless check[:allowed]

      invitee = Member.where(email: email).first
      if invitee
        raise ::Error::UnprocessableEntity.new('That person is already part of a household.') if invitee.household_role.present?
        if join_blocker(invitee)
          raise ::Error::UnprocessableEntity.new(
            "#{email} already has a membership that has not ended yet, so they cannot join a household until it ends."
          )
        end
      end

      # Counted before anything is created or the link is replaced, so a refused send changes nothing.
      HouseholdInviteLimit.claim!(sender_id: primary.id, recipient_email: email)

      group = household_for(primary) || create_household!(primary)
      invitation = group_invitations(group).outstanding.where(invited_email: email).first
      if invitation
        verb = 'resent'
      else
        invitation = HouseholdInvitation.new(group_id: group.id, invited_email: email, invited_by_id: primary.id,
                                             token_digest: SecureRandom.hex(32), expires_at: Time.current)
        verb = 'sent'
      end
      deliver(invitation, primary, "household_invitation_#{verb}", "invited #{email}")
      invitation
    end

    def resend!(invitation, primary:)
      group = owned_group!(invitation, primary)
      raise ::Error::UnprocessableEntity.new('That invitation was already accepted.') if invitation.status == 'accepted'
      raise ::Error::UnprocessableEntity.new('That invitation was cancelled. Send a new one instead.') if invitation.status == 'revoked'
      raise ::Error::UnprocessableEntity.new('Your household payment has not been accepted yet.') unless group.payment_accepted?

      HouseholdInviteLimit.claim!(sender_id: primary.id, recipient_email: invitation.invited_email)
      deliver(invitation, primary, 'household_invitation_resent', "sent a new link to #{invitation.invited_email}")
      invitation
    end

    # Cancels the invitation: its link stops working and the seat is free again.
    def revoke!(invitation, primary:)
      group = owned_group!(invitation, primary)
      raise ::Error::UnprocessableEntity.new('That invitation was already accepted. Ask staff to remove them from the household.') if invitation.status == 'accepted'

      invitation.update!(status: 'revoked', revoked_at: Time.current) unless invitation.status == 'revoked'
      audit(group, primary, 'household_invitation_revoked', "cancelled the invitation to #{invitation.invited_email}")
      invitation
    end

    # The invited person, signed in, joins the household.
    def accept!(member:, token:)
      invitation = HouseholdInvitation.find_by_token(token)
      raise ::Error::UnprocessableEntity.new('This invitation link is not valid.') unless invitation

      group = invitation.group
      primary = group&.member
      raise ::Error::UnprocessableEntity.new('This household no longer exists.') unless group && primary
      raise ::Error::UnprocessableEntity.new('This invitation was cancelled.') if invitation.status == 'revoked'
      raise ::Error::UnprocessableEntity.new('This invitation was already used.') if invitation.status == 'accepted'
      if invitation.expired?
        raise ::Error::UnprocessableEntity.new("This invitation has expired. Ask #{primary.firstname} to send you a new one.")
      end
      unless member.email.to_s.downcase == invitation.invited_email
        raise ::Error::Forbidden.new("Sign in with the email address the invitation was sent to (#{mask(invitation.invited_email)}).")
      end
      raise ::Error::UnprocessableEntity.new('You are already part of a household.') if member.household_role.present?
      unless group.payment_accepted?
        raise ::Error::UnprocessableEntity.new("#{primary.firstname}'s household payment has not been accepted yet, so you cannot join yet. Ask them to check their payment.")
      end

      blocker = join_blocker(member)
      raise ::Error::UnprocessableEntity.new(blocker) if blocker

      unless ::Service::AddressMatch.members_match?(primary, member)
        raise ::Error::UnprocessableEntity.new(
          "Address mismatch: your address (#{::Service::AddressMatch.describe(member)}) does not match the household address " \
          "(#{::Service::AddressMatch.describe(primary)}). Update your address on your profile, then press Join again. " \
          'The street number, street name and postal code must match.'
        )
      end

      group.add_subordinate(member, invitation: invitation)
      invitation.update!(status: 'accepted', accepted_member_id: member.id, accepted_at: Time.current)

      audit(group, member, 'household_member_added', "joined by invitation from #{primary.fullname}",
            subject: primary, slack: true, snapshot: { groupName: group.groupName, secondary_member_id: member.id.to_s, secondary_name: member.fullname, source: 'invitation' })
      MemberMailer.household_joined(member.id.to_s, primary.id.to_s).deliver_later
      MemberMailer.household_joined(primary.id.to_s, member.id.to_s).deliver_later
      group
    end

    # What the public link page may show, without signing in: nothing about the household beyond who invited them, and only
    # while the invitation can still be used. A cancelled, expired or used link says so and nothing else.
    def public_info(token)
      invitation = HouseholdInvitation.find_by_token(token)
      return nil unless invitation
      return { status: invitation.display_status, inviter_name: nil, invited_email: nil, expires_at: invitation.expires_at } unless invitation.open?

      primary = invitation.group&.member
      {
        status: invitation.display_status,
        inviter_name: primary ? "#{primary.firstname} #{primary.lastname.to_s[0]}." : nil,
        invited_email: invitation.invited_email,
        expires_at: invitation.expires_at
      }
    end

    # What the signed-in invitee sees before pressing Join, including the address they must match. Only an invitation that
    # can still be used shows the household's name and address: a cancelled, expired or used link (the primary may have moved
    # since, or removed them) gets its status and nothing about the household.
    def preview(member:, token:)
      invitation = HouseholdInvitation.find_by_token(token)
      raise ::Error::UnprocessableEntity.new('This invitation link is not valid.') unless invitation
      unless member.email.to_s.downcase == invitation.invited_email
        raise ::Error::Forbidden.new("Sign in with the email address the invitation was sent to (#{mask(invitation.invited_email)}).")
      end

      unless invitation.open?
        return {
          status: invitation.display_status,
          primary_name: nil,
          household_address: nil,
          your_address: ::Service::AddressMatch.describe(member),
          address_matches: false,
          payment_accepted: false,
          blocked_reason: nil,
          expires_at: invitation.expires_at
        }
      end

      group = invitation.group
      primary = group&.member
      {
        status: invitation.display_status,
        primary_name: primary&.fullname,
        household_address: primary ? ::Service::AddressMatch.describe(primary) : nil,
        your_address: ::Service::AddressMatch.describe(member),
        address_matches: !!(primary && ::Service::AddressMatch.members_match?(primary, member)),
        payment_accepted: !!group&.payment_accepted?,
        blocked_reason: join_blocker(member),
        expires_at: invitation.expires_at
      }
    end

    # Why this person cannot join a household yet because they already have a membership, or nil. Only ever shown to the
    # person themselves (they may be told their own dates); the primary is only told that they cannot join.
    def join_blocker(member)
      now_ms = Time.now.to_i * 1000
      paid_until = member.expirationTime.present? && member.expirationTime > now_ms ? Time.at(member.expirationTime / 1000).strftime('%B %-d, %Y') : nil
      if member.active_membership_subscription?
        when_text = paid_until ? "after your paid time ends on #{paid_until}" : 'once it has ended'
        return "You have an active subscription. Cancel it, and you can join this household #{when_text}. Ask the household's primary member to send the invitation again if it has expired by then."
      end
      if paid_until
        return "Your membership runs until #{paid_until}. You can join this household after it expires. Ask the household's primary member to send the invitation again if it has expired by then."
      end
      nil
    end

    private

    def denied(reason)
      { allowed: false, reason: reason }
    end

    def household_plan_current?(member)
      latest = Invoice.where(resource_class: 'member', resource_id: member.id.to_s).order_by(created_at: :desc).first
      latest&.plan_id.to_s.downcase.include?('household')
    end

    def household_for(member)
      return nil unless member.household_role

      Group.where(groupName: member.groupName.to_s).first
    end

    def group_invitations(group)
      HouseholdInvitation.where(group_id: group.id)
    end

    def create_household!(primary)
      group = Group.create!(groupName: primary.id.to_s, groupRep: primary.fullname, expiry: primary.expirationTime)
      primary.update_attributes!(groupName: primary.id.to_s)
      audit(group, primary, 'household_created', "created the household by sending the first invitation",
            slack: true, snapshot: { groupName: group.groupName, groupRep: group.groupRep, primary_member_id: primary.id.to_s })
      group
    end

    def owned_group!(invitation, primary)
      group = invitation.group
      unless group && group.groupName.to_s == primary.id.to_s
        raise ::Error::Forbidden.new('Only the primary member of this household can do that.')
      end

      group
    end

    def deliver(invitation, primary, event_type, details)
      raw = invitation.issue_token!
      HouseholdInvitationMailJob.perform_later(invitation.id.to_s, raw)
      audit(invitation.group, primary, event_type, details, snapshot: { invited_email: invitation.invited_email, expires_at: invitation.expires_at })
    end

    def audit(group, actor, event_type, details, subject: nil, slack: false, snapshot: nil)
      ::Service::AuditLogger.log(
        log_type:        'member',
        event_type:      event_type,
        resource_type:   'Group',
        resource_id:     group.id,
        actor:           actor,
        subject:         subject || actor,
        message_details: "#{actor.fullname} #{details}".strip,
        after_snapshot:  snapshot,
        slack_channel:   (::Service::SlackConnector.members_relations_channel if slack)
      )
    end

    def household_summary(group, viewer, role)
      primary = group.member
      members = group.secondary_members.map do |m|
        { id: m.id.to_s, name: m.fullname, email: (m.email if role == :primary), fob_issued: m.access_cards.any?, status: m.status,
          expiration_time: m.expirationTime }
      end
      summary = {
        id: group.id.to_s,
        display_name: group.group_display_name,
        size: group.size,
        seats_used: group.seats_used,
        payment_accepted: group.payment_accepted?,
        expiration_time: group.expiry,
        primary: primary && { id: primary.id.to_s, name: primary.fullname, fob_issued: primary.access_cards.any? },
        members: members
      }
      if role == :primary
        summary[:invitations] = group_invitations(group).where(:status.in => %w[pending]).order_by(created_at: :desc).map do |i|
          { id: i.id.to_s, email: i.invited_email, status: i.display_status, expires_at: i.expires_at, sent_count: i.sent_count }
        end
      end
      summary
    end

    def mask(email)
      local, domain = email.to_s.split('@', 2)
      return email.to_s if domain.nil?

      "#{local[0]}#{'*' * [local.length - 1, 1].max}@#{domain}"
    end
  end
end
