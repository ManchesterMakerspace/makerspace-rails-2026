class Billing::SubscriptionsController < BillingController
    before_action :verify_customer, :verify_own_subscription

  def show
    subscription = ::BraintreeService::Subscription.get_subscription(@gateway, params[:id])
    ::PayNow.ensure_failure_reason(@gateway, subscription)
    render json: subscription, serializer: BraintreeService::SubscriptionSerializer, adapter: :attributes and return
  end

  def update
    subscription_update = {
      id: params[:id],
      payment_method_token: subscription_params[:payment_method_token]
    }
    subscription = ::BraintreeService::Subscription.update(@gateway, subscription_update)
    # A new payment method gives a hard-declined card's replacement a fresh start, so Pay now is available again.
    ::PaymentFailure.clear!(::PayNow.invoice_for(params[:id]))

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'subscription_updated',
      resource_type:  'Subscription',
      resource_id:    current_member.id,
      actor:          current_member,
      subject:        current_member,
      after_snapshot: { subscription_id: params[:id],
                        payment_method_token: subscription_params[:payment_method_token] },
      slack_channel:  ::Service::SlackConnector.logs_channel
    )

    render json: subscription, serializer: BraintreeService::SubscriptionSerializer, adapter: :attributes and return
  end

  # Pay now: charge the past-due balance of the member's own subscription right away (see PayNow). Expected refusals and
  # declines answer with JSON directly rather than raising, so they do not post an alert to the logs channel.
  def pay_now
    outcome = ::PayNow.attempt!(@gateway, current_member, params[:id])
    subscription = ::BraintreeService::Subscription.get_subscription(@gateway, params[:id])

    if outcome.paid?
      render json: subscription, serializer: BraintreeService::SubscriptionSerializer, adapter: :attributes and return
    end

    info = ::PayNow.info_for(subscription)
    render json: {
      status: 422,
      error: 'payment_declined',
      message: declined_message(outcome.failure),
      failureType: outcome.failure[:type],
      failureMessage: outcome.invoice.reload.last_failure_message,
      canPayNow: info[:can_pay_now],
      payNowBlockedReason: info[:blocked_reason],
      nextPayNowAt: info[:next_at]&.iso8601
    }, status: 422
  rescue ::PayNow::Refused => refusal
    render json: {
      status: refusal.status,
      error: refusal.reason,
      message: refusal.message,
      nextPayNowAt: refusal.retry_at&.iso8601
    }, status: refusal.status
  end

  def cancellation_impact
    reservations = ReservationLifecycleService.cancellation_impact(@subscription_resource)
    render json: {
      reservationCount: reservations.length,
      membershipExpiresAt: membership_expiration_for(@subscription_resource)&.iso8601,
      reservations: reservations.map do |reservation|
        {
          id: reservation.id.to_s,
          title: reservation.title,
          calendarHtmlLink: reservation.calendar_html_link,
          startAt: reservation.start_at.iso8601,
          endAt: reservation.end_at.iso8601
        }
      end
    }
  end

  def destroy
    result = ::BraintreeService::Subscription.cancel(@gateway, params[:id])

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'subscription_cancelled',
      resource_type:  'Subscription',
      resource_id:    current_member.id,
      actor:          current_member,
      subject:        current_member,
      after_snapshot: { subscription_id: params[:id] },
      slack_channel:  ::Service::SlackConnector.logs_channel
    )

    render json: {}, status: 204 and return
  end

  private
  def subscription_params
    params.require(:payment_method_token)
    params.permit(:payment_method_token)
  end

  def declined_message(failure)
    reason = failure[:message]
    message = reason ? "Your payment did not go through: #{reason}." : "Your payment did not go through."
    message += " Update your payment method before trying again." if failure[:type] == ::PaymentFailure::HARD
    message
  end

  def verify_own_subscription
    @subscription_resource = current_member.find_subscribed_resource(params[:id])
    raise Error::NotFound.new if @subscription_resource.nil?
  end

  def verify_customer
    raise Error::Braintree::MissingCustomer.new unless current_member.customer_id
  end

  def membership_expiration_for(resource)
    case resource
    when Member
      resource.membership_expires_at
    when Group
      return nil if resource.expiry.blank?
      Time.at(resource.expiry.to_f / 1000).utc
    end
  end
end
