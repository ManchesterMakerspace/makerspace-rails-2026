# Sends the household invitation email. The link in it carries the invitation's secret token, which is not stored anywhere
# (only its digest is), so it travels as this job's argument. Two places would otherwise copy that argument:
#   * Active Job logs a job's arguments when it is enqueued and when it runs, so argument logging is switched off.
#   * Honeybadger's Active Job plugin sends a failing job's arguments with the error report. A failure is therefore reported
#     here with the invitation id only, and is not re-raised (re-raising is what makes the plugin attach the arguments).
#     Nothing is lost: the invitation stays open, and the primary can press Resend.
class HouseholdInvitationMailJob < ApplicationJob
  queue_as :mailers
  self.log_arguments = false

  def perform(invitation_id, token)
    MemberMailer.household_invitation(invitation_id, token).deliver_now
  rescue StandardError => error
    ::Service::ErrorReporter.notify(error, context: { invitation_id: invitation_id.to_s, job: self.class.name })
  end
end
