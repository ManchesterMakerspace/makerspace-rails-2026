# Awards and reverses the silent credit attached to a checkout completed by an
# ordinary, individually assigned checkout approver.
class CheckoutApproverCredit
  VALUE = 0.25

  def self.award!(checkout)
    actor = checkout.approved_by
    return unless additional_approver?(actor, checkout.tool)
    return if checkout.volunteer_credit_id.present?

    credit = VolunteerCredit.find_or_create_by!(tool_checkout_id: checkout.id) do |row|
      row.member_id = actor.id
      row.issued_by_id = actor.id
      row.description = "Completed checkout for #{checkout.member.fullname} on #{checkout.tool.name}"
      row.credit_value = VALUE
      row.status = "approved"
    end
    checkout.set(volunteer_credit_id: credit.id)
    credit
  end

  def self.reverse!(checkout)
    credit = VolunteerCredit.find_by(id: checkout.volunteer_credit_id) ||
      VolunteerCredit.find_by(tool_checkout_id: checkout.id)
    return unless credit&.status == "approved" && !credit.reversed

    now = Time.current
    VolunteerCredit.create!(
      member_id: credit.member_id,
      issued_by_id: credit.issued_by_id,
      description: "Reversal: #{credit.description}",
      credit_value: -credit.credit_value,
      status: "reversal",
      reversal_of_id: credit.id,
      reversal_reason: "Tool checkout revoked",
      reversed_by_id: credit.issued_by_id,
      reversed_at: now,
      earned_while_em_active: credit.earned_while_em_active
    )
    credit.update!(reversed: true, reversed_by_id: credit.issued_by_id, reversed_at: now)
    if credit.discount_applied
      reversed_by = Member.find_by(id: credit.issued_by_id)
      credit.send(:notify_braintree_review_needed, reversed_by, "Tool checkout revoked") if reversed_by
    end
  end

  def self.additional_approver?(actor, tool)
    return false unless actor && tool
    return false if actor.role.in?(%w[admin board_member]) || actor.manages_shop?(tool.shop_id)

    CheckoutApprover.find_by(member_id: actor.id)&.can_approve_tool?(tool) || false
  end
  private_class_method :additional_approver?
end
