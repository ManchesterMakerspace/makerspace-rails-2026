class DocumentUploadJob < ApplicationJob
  include Service::SlackConnector
  include ::Service::GoogleDrive

  queue_as :slack

  # Fires only once retries are exhausted, for ANY StandardError -- not just
  # Error::Google::Upload. The narrower rescue this replaced meant an upload
  # to a misconfigured destination folder, a PDF-generation bug, or
  # any other failure type retried silently and then died with no alert and
  # no rollback: the resource stayed marked "signed" pointing at a document
  # that was never actually created.
  retry_on StandardError, attempts: 5 do |job, error|
    _base64_signature, document_type, resource_id = job.arguments
    job.send(:report_upload_failure, document_type, resource_id, error)
  end

  def perform(base64_signature, document_type, resource_id)
    resource, member, _on_fail = resolve_resource(document_type, resource_id)
    overloads = document_type == "rental_agreement" ? { rental: resource } : {}

    document = upload_document(document_type, member, overloads, base64_signature)
    verify_uploaded!(resource, document_type)
    MemberMailer.send_document(document_type, member.id.as_json, document).deliver_later
  end

  private

  def resolve_resource(document_type, resource_id)
    case document_type
    when "member_contract"
      resource = Member.find(resource_id)
      [resource, resource, -> { resource.update_attributes!(member_contract_signed_date: nil) }]
    when "rental_agreement"
      resource = Rental.find(resource_id)
      [resource, resource.member, -> { resource.update_attributes!(contract_on_file: false) }]
    end
  end

  # An upload can report success without the file actually landing where
  # get_document will later look (e.g. a misconfigured destination folder).
  # Confirming it's really there turns that into a normal, detectable
  # failure instead of a silent one.
  def verify_uploaded!(resource, document_type)
    return if ::Service::GoogleDrive.document_uploaded?(resource, document_type)
    raise Error::Google::Upload.new("Upload appeared to succeed but the file could not be found in Drive afterward")
  end

  # Alerts Slack, writes a durable audit log entry, and rolls back the
  # resource's "signed" state -- called once retries are exhausted for any
  # failure, whether raised by the upload itself or by verify_uploaded!.
  def report_upload_failure(document_type, resource_id, error)
    resource, member, on_fail = resolve_resource(document_type, resource_id)

    member_name = member&.fullname || "Unknown member (#{resource_id})"
    message = "Error uploading #{member_name}'s #{document_type} signature after all retries. " \
      "Error: #{error.class}: #{error.message}"

    ::Service::SlackConnector.send_slack_message(message)
    ::Service::AuditLogger.log(
      log_type:      'member',
      event_type:    'document_upload_failed',
      resource_type: document_type == 'member_contract' ? 'Member' : 'Rental',
      resource_id:   resource_id,
      subject:       member,
      message_details: message
    )
    on_fail&.call
  rescue => reporting_error
    # A bug here must never hide the original upload failure.
    Rails.logger.error("[DocumentUploadJob] failed to report upload failure: #{reporting_error}")
  end
end
