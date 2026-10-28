require 'rails_helper'

RSpec.describe AuditLog, '.category_for' do
  # Every event type the application writes today. A new one lands in "other"
  # until it is mapped; this list is a reminder to map it.
  known_event_types = %w[
    blocked_login_attempt board_reservation_created braintree_order_id_ownership_mismatch braintree_payment_unmatched
    card_updated checkout_approver_created checkout_approver_deleted checkout_approver_updated checkout_canvas_sync_failed
    contract_signed document_upload_failed earned_membership_reactivated earned_membership_renewed earned_membership_suspended
    fix_ticket_assignee_expired fob_checkout_lookup google_api_permission_denied household_created household_dissolved
    household_exit_auto household_member_added household_member_removed invoice_created invoice_deleted
    invoice_force_cancelled invoice_option_created invoice_option_delete_blocked invoice_option_deleted
    invoice_option_updated invoice_settled invoice_settlement_reversed invoice_updated location_created location_deleted
    location_updated member_registered member_restored member_soft_deleted member_updated membership_revoked
    password_changed payment_method_added payment_method_removed permissions_updated portal_setting_changed
    refund_requested rental_agreement_declined rental_agreement_signed rental_approved rental_cancelled rental_created
    rental_denied rental_requested rental_spot_created rental_spot_deleted rental_spot_updated rental_type_created
    rental_type_deleted rental_type_updated rental_updated rental_vacated reservation_blackout_deleted
    shop_availability_changed shop_created shop_deleted shop_requestor_annotation_updated shop_resource_managers_changed
    shop_updated slack_email_mismatch slack_identity_conflict slack_identity_conflict_dismissed
    slack_identity_manually_reassigned slack_invite_failed subscription_auto_cancelled_payment_failure
    subscription_cancelled subscription_updated system_email_sent template_action_failed ticket_closed
    ticket_reporter_revealed tool_availability_changed tool_checkout_created tool_checkout_expiration_changed
    tool_checkout_reinstated tool_checkout_request_declined tool_checkout_request_timed_out tool_checkout_revoked
    tool_created tool_deleted tool_group_checkout_created tool_notes_updated tool_requestor_annotation_updated tool_updated
    totp_disabled totp_enabled totp_reset transaction_created transaction_refunded volunteer_task_credit_changed
    slack_message_sent slack_message_failed
    google_drive_access_confirmed google_drive_provisioning_failed google_drive_provisioning_blocked
    google_drive_previous_email_revoked slack_invite_succeeded slack_promotion_succeeded
    slack_manual_invite_required slack_manual_promotion_required
    slack_previous_identity_revoked slack_previous_identity_detached card_assigned card_released
  ]

  it 'maps every event type the application writes to a category' do
    unmapped = known_event_types.select { |event_type| described_class.category_for(event_type) == 'other' }
    expect(unmapped).to be_empty
  end

  it 'never puts one event type in two categories, so the database filter agrees with category_for' do
    known_event_types.each do |event_type|
      matches = AuditLog::CATEGORIES.select do |_key, rule|
        rule[:exact].include?(event_type) || rule[:prefixes].any? { |prefix| event_type.start_with?(prefix) }
      end
      expect(matches.keys.size).to eq(1), "#{event_type} matches #{matches.keys.inspect}"
    end
  end

  it 'separates Slack messages from Slack account events' do
    expect(described_class.category_for('slack_message_sent')).to eq('slack')
    expect(described_class.category_for('slack_invite_failed')).to eq('members')
    expect(described_class.category_for('slack_identity_conflict')).to eq('members')
  end

  it 'files account provisioning events (Slack invite and promotion, Google Drive access) under members' do
    %w[google_drive_provisioning_failed google_drive_access_confirmed slack_promotion_succeeded
       slack_manual_invite_required slack_manual_promotion_required slack_previous_identity_detached].each do |event_type|
      expect(described_class.category_for(event_type)).to eq('members'), event_type
    end
  end

  it 'puts an unknown event type in other' do
    expect(described_class.category_for('something_new')).to eq('other')
  end
end
