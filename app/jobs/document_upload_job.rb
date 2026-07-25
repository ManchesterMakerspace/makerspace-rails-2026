class DocumentUploadJob < ApplicationJob
  include Service::SlackConnector
  include ::Service::GoogleDrive
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  queue_as :integrations

  def perform(pending_upload_id)
    pending = PendingDocumentUpload.find_by(id: pending_upload_id)
    return if pending.nil?

    MemoryHeavyJobLock.with_lock(expires_in: 15.minutes) do
      document_type = pending.document_type
      resource_id = pending.resource_id
      base64_signature = pending.base64_data

      if document_type == "member_contract"
        resource = Member.find(resource_id)
        return pending.destroy if resource.nil?
        member = resource
        overloads = {}
        on_fail = -> { resource.update_attributes!(member_contract_signed_date: nil) }
      elsif document_type == "rental_agreement"
        resource = Rental.find(resource_id)
        return pending.destroy if resource.nil?
        member = resource.member
        overloads = { rental: resource }
        on_fail = -> { resource.update_attributes!(contract_on_file: false) }
      else
        return pending.destroy
      end

      document = upload_document(document_type, member, overloads, base64_signature)
      MemberMailer.send_document(document_type, member.id.as_json, document).deliver_later
      pending.destroy
    rescue Error::Google::Upload => err
      member_name = member&.fullname || "Unknown member (#{resource_id})"
      enque_message("Error uploading #{member_name}'s #{document_type} signature. Error: #{err}")
      on_fail&.call
      raise
    end
  end
end
