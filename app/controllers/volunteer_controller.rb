# VolunteerController
#
# Member-facing volunteer endpoints.
#
class VolunteerController < AuthenticationController

  # GET /api/volunteer/credits
  def credits
    credits = VolunteerCredit.where(member_id: current_member.id)
                             .order_by(created_at: :desc)
    render json: credits, each_serializer: VolunteerCreditSerializer, adapter: :attributes
  end

  # GET /api/volunteer/summary
  def summary
    member_id       = current_member.id
    is_earned       = EarnedMembership.where(member_id: member_id).exists?
    year_count      = VolunteerCredit.year_count_for(member_id)
    pending_count   = VolunteerCredit.pending.where(member_id: member_id).count
    discount_active = VolunteerCredit.discount_amount > 0.0

    if discount_active
      discounts_used = VolunteerCredit.discounts_applied_this_year_for(member_id)
      threshold      = VolunteerCredit.credits_per_discount
      max_discounts  = VolunteerCredit.max_discounts_per_year

      message = if is_earned
        nil
      elsif discounts_used >= max_discounts
        "Maximum discounts reached for this year (#{max_discounts}). Resets January 1st."
      else
        credits_until_next = [(threshold * (discounts_used + 1)) - year_count, 0.0].max
        if credits_until_next == 0.0
          'Discount applied to your next billing cycle!'
        else
          "#{credits_until_next} credit#{'s' if credits_until_next != 1.0} until your next discount."
        end
      end
    else
      discounts_used = nil
      threshold      = nil
      max_discounts  = nil
      message        = nil
    end

    render json: {
      year_count:           year_count,
      discounts_used:       discounts_used,
      max_discounts:        max_discounts,
      credits_per_discount: threshold,
      pending_count:        pending_count,
      is_earned_member:     is_earned,
      discount_active:      discount_active,
      message:              message
    }
  end

  # GET /api/volunteer/tasks
  def tasks
    tasks = VolunteerTask.active.order_by(task_number: :asc)
    render json: tasks, each_serializer: VolunteerTaskSerializer, adapter: :attributes
  end

  # GET /api/volunteer/events
  def events
    events = VolunteerEvent.active_events.order_by(created_at: :desc)
    render json: events, each_serializer: VolunteerEventSerializer, adapter: :attributes
  end

  # POST /api/volunteer/tasks/:id/claim
  def claim_task
    task = VolunteerTask.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(VolunteerTask, { id: params[:id] }) if task.nil?

    task.claim!(current_member)
    render json: task, serializer: VolunteerTaskSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'Task is no longer available' }, status: :unprocessable_entity
  end

  # POST /api/volunteer/tasks/:id/complete
  def complete_task
    task = VolunteerTask.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(VolunteerTask, { id: params[:id] }) if task.nil?

    task.mark_pending!(current_member)

    ::Service::SlackConnector.send_slack_message(
      "✅ *#{current_member.fullname}* has completed task *#{task.title}* (#{task.display_number}) and is awaiting verification.",
      VolunteerCredit.pending_slack_channel
    )

    render json: task, serializer: VolunteerTaskSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'You cannot mark this task as complete' }, status: :unprocessable_entity
  end

  # POST /api/volunteer/events/:id/checkin
  def checkin_event
    event = VolunteerEvent.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(VolunteerEvent, { id: params[:id] }) if event.nil?

    if event.status != 'open'
      render json: { error: 'Event is not open for check-in' }, status: :unprocessable_entity and return
    end

    if event.attendee_ids.include?(current_member.id)
      render json: { error: 'You are already checked in to this event' }, status: :unprocessable_entity and return
    end

    event.checkin!(current_member)
    render json: event, serializer: VolunteerEventSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'Unable to check in to this event' }, status: :unprocessable_entity
  end
end
