class BraintreeService::SubscriptionSerializer < ActiveModel::Serializer
  attributes  :id,
              :plan_id,
              :status,
              :amount,
              :failure_count,
              :days_past_due,
              :billing_day_of_month,
              :first_billing_date,
              :next_billing_date,
              :member_id,
              :member_name,
              :resource_class,
              :resource_id,
              :payment_method_token,
              :can_pay_now,
              :pay_now_blocked_reason,
              :last_failure_message,
              :next_pay_now_at

  # Convert BigDecimal next_bill_amount to currency
  def amount
    object.next_billing_period_amount
  end

  # Pay now (see PayNow): whether the member can charge this past-due subscription now, and if not, why and until when.
  def can_pay_now
    pay_now[:can_pay_now]
  end

  # nil, or "hard_decline" (change the payment method first), "cooldown", "daily_cap" or "unavailable".
  def pay_now_blocked_reason
    pay_now[:blocked_reason]
  end

  # Plain wording for why the last charge failed (for example "insufficient funds"), or nil when unknown.
  def last_failure_message
    pay_now[:failure_message]
  end

  def next_pay_now_at
    pay_now[:next_at]&.iso8601
  end

  def member_id
    object.member && object.member.id
  end

  def member_name
    object.member && object.member.fullname
  end

  def resource_class
    object.resource && object.resource.class.name
  end

  def resource_id
    object.resource && object.resource.id
  end

  private

  def pay_now
    @pay_now ||= ::PayNow.info_for(object)
  end
end
