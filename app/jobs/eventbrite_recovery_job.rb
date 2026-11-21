class EventbriteRecoveryJob < ApplicationJob
  MemberSnapshot = Data.define(:id, :email, :eventbrite_link_pending_at)
  private_constant :MemberSnapshot

  def perform
    EventbriteIntegration::Configuration.scope_organizations(EventbriteEvent.where(:inventory_refresh_at.lte => Time.current)).limit(100).pluck(:id).each do |id|
      EventbriteInventoryRefreshJob.perform_now(id.to_s)
    end
    pending_slack = EventbriteSlackDelivery.where(failed_at: nil, expired: false, :due_at.lte => Time.current,
      mode: Service::SlackConnector.message_destination_mode)
    EventbriteIntegration::Configuration.scope_organizations(pending_slack).limit(100).pluck(:id).each do |id|
      EventbriteSlackDeliveryJob.perform_now(id.to_s)
    end
    Member.unscoped.where(:eventbrite_link_pending_at.ne => nil).limit(100)
      .pluck(:id, :email, :eventbrite_link_pending_at).each do |id, email, marker|
      member = MemberSnapshot.new(id, email, marker)
      EventbriteIntegration::MemberLinker.reconcile(member)
    rescue StandardError => error
      Rails.logger.error("Eventbrite member reconciliation #{member.id}: #{error.class.name}")
    end
    EventbriteWebhookDelivery.where(completed_at: nil, failed_at: nil, :due_at.lte => Time.current)
      .where('$or' => [{ lease_until: nil }, { lease_until: { '$lt' => Time.current } }]).limit(100).pluck(:id).each do |id|
      # Cron runners must finish durable work before exiting; their async queue dies with them.
      EventbriteDeliveryJob.perform_now(id.to_s)
    end
  end
end
