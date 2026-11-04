class CardEnrollment
  class Invalid < StandardError; end

  def initialize(actor, workflow)
    @actor, @workflow = actor, workflow
  end

  def authorize!
    @actor.reload
    allowed = @workflow == 'admin' ? %w[admin board_member].include?(@actor.role) && @actor.fully_active_unexpired? : @actor.fob_issuer?
    raise Error::Forbidden.new unless allowed
  end

  def prepare!(member_id, uid, verified)
    raise Invalid, 'Confirm member identification before enrollment.' unless verified == true
    raise Invalid, 'A member ObjectId is required.' unless (member_id.is_a?(String) || member_id.is_a?(BSON::ObjectId)) && member_id.to_s.match?(/\A[0-9a-f]{24}\z/i)
    raise Invalid, 'A Classic card with a 4- or 7-byte uppercase hexadecimal UID is required.' unless uid.is_a?(String) && uid.match?(/\A(?:[0-9A-F]{8}|[0-9A-F]{14})\z/)
    result = nil
    CardManagement.transaction do
      authorize_and_fence!
      member = Member.find(member_id)
      raise Error::NotFound.new unless member
      row = NfcCardEnrollment.lock!(uid)
      if row.state == 'completed' && row.member_id == member.id && Card.where(id: row.card_id, uid: uid, member_id: member.id).exists?
        accessible!(row)
        result = status(row)
        next
      end
      eligible!(member)
      if row.state == 'pending'
        accessible!(row)
        raise CardManagement::Conflict, 'Enrollment belongs to another recipient.' unless row.member_id == member.id
        check_assignment!(row, member)
      else
        raise CardManagement::Conflict, 'This UID is already registered.' if Card.where(uid: uid).exists?
        member.inc(card_operation_version: 1)
        row.update!(attempt_id: SecureRandom.uuid, state: 'pending', revision: row.revision + 1,
          member_id: member.id, actor_id: @actor.id, card_id: BSON::ObjectId.new,
          assignment_version: member.card_operation_version, workflow: @workflow,
          sealed: NfcCredentialCodec.seal(NfcCredentialCodec.generate(uid)), created_at: Time.current, completed_at: nil)
      end
      audit!(row, 'card_enrollment_prepared')
      result = status(row).merge(material: NfcCredentialCodec.open(row.sealed))
    end
    result
  end

  def show(id)
    authorize!
    row = find!(id)
    accessible!(row)
    status(row)
  end

  def commit!(id, revision, digest)
    authorize!
    result = nil
    effects = nil
    CardManagement.transaction do
      effects = nil
      authorize_and_fence!
      row = find!(id)
      row.inc(fence: 1)
      accessible!(row)
      expected = NfcCredentialCodec.open(row.sealed).fetch('digest')
      unless revision == row.revision && digest.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(expected, digest)
        raise CardManagement::Conflict, 'Enrollment revision or readback verification changed.'
      end
      if row.state == 'completed'
        card = Card.where(id: row.card_id, uid: row.id, member_id: row.member_id).first
        raise CardManagement::Conflict, 'Completed assignment has changed.' unless card
      else
        raise CardManagement::Conflict, 'Enrollment is not pending.' unless row.state == 'pending'
        member = Member.find(row.member_id)
        raise Error::NotFound.new unless member
        eligible!(member)
        check_assignment!(row, member)
        card, assignment_audit = CardManagement.assign_in_transaction!(
          { id: row.card_id, member_id: row.member_id, uid: row.id }, @actor,
          uid_source: 'nfc', initial_only: @workflow == 'issuer')
        NfcCardCredential.create!(id: card.id, memberId: member.id, uid: row.id, state: 'active',
          sealed: row.sealed, createdAt: row.created_at, enrolledAt: Time.current,
          enrolledByMemberId: @actor.id, enrollmentSource: 'android')
        row.update!(state: 'completed', completed_at: Time.current)
        audit!(row, 'card_enrollment_completed')
        effects = [card, assignment_audit]
      end
      result = status(row)
    end
    if effects
      CardManagement.assignment_effects!(*effects)
      FobIssuanceNotifier.notify(effects.first.member, @actor) if @workflow == 'issuer'
    end
    result
  end

  private

  def authorize_and_fence!
    authorize!
    @actor.inc(nfc_authorization_fence: 1)
    if @workflow == 'issuer'
      Tool.where(grants_fob_issuance: true).each do |tool|
        tool.inc(nfc_authorization_fence: 1)
        ToolCheckout.where(member_id: @actor.id, tool_id: tool.id, revoked_at: nil, superseded_by_id: nil).each do |checkout|
          checkout.inc(nfc_authorization_fence: 1) if checkout.active?
        end
      end
    end
  end

  def eligible!(member)
    raise Invalid, 'Member must have a signed member contract.' unless member.member_contract_signed_date.present?
    if @workflow == 'issuer' && (member.id == @actor.id || member.status == 'revoked' || !member.awaiting_first_fob?)
      raise Error::Forbidden.new
    end
  end

  def accessible!(row)
    raise Error::Forbidden.new if @workflow == 'issuer' && (row.actor_id != @actor.id || row.workflow != 'issuer')
  end

  def check_assignment!(row, member)
    raise CardManagement::Conflict, 'Member assignment changed. Contact an administrator to recover this enrollment.' unless row.assignment_version == member.card_operation_version
    member.inc(nfc_enrollment_fence: 1)
  end

  def find!(id)
    NfcCardEnrollment.find_by(attempt_id: id) || raise(Error::NotFound.new)
  end

  def status(row)
    { id: row.attempt_id, uid: row.id, memberId: row.member_id.to_s,
      cardId: row.card_id.to_s, revision: row.revision, state: row.state }
  end

  def audit!(row, event)
    log = Service::AuditLogger.log(log_type: 'member', event_type: event,
      resource_type: 'Card', resource_id: row.card_id, actor: @actor, subject: Member.find(row.member_id),
      after_snapshot: status(row))
    raise CardManagement::Unavailable, 'Unable to record enrollment audit.' unless log
  end
end
