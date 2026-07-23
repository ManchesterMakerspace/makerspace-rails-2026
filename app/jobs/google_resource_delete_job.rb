class GoogleResourceDeleteJob < ApplicationJob
  queue_as :default

  def perform(resource_id, label_source_id = nil)
    delete_resource(resource_id, label_source_id)
    delete_label(label_source_id)
  end

  private

  def delete_resource(resource_id, audit_resource_id)
    Service::GoogleWorkspace.delete_resource!(resource_id, audit_resource_id: audit_resource_id)
  rescue => error
    report(error, "google_resource_delete_job.resource", audit_resource_id)
  end

  def delete_label(label_source_id)
    Service::GoogleWorkspace.delete_label!(label_source_id)
  rescue => error
    report(error, "google_resource_delete_job.label", label_source_id)
  end

  def report(error, operation, resource_id)
    Service::GoogleApiErrorReporter.report_if_permission_denied(
      error,
      operation: operation,
      resource_type: "GoogleCalendarResource",
      resource_id: resource_id
    )
    Honeybadger.notify(error) if defined?(Honeybadger)
    Rails.logger.warn(
      "Google resource deletion failed for #{resource_id}: " \
      "#{Service::GoogleApiErrorReporter.full_error_message(error)}"
    )
  end
end
