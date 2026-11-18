# Profile-only browser acceptance fixtures. No reset, processor call, or real mail.
abort 'Paid membership browser fixtures require RAILS_ENV=test' unless Rails.env.test?
Service::DatabaseSafety.ensure_safe_mlab_uri!(operation: 'paid membership browser fixtures')
ActiveJob::Base.queue_adapter = :test
MembershipPaidCreditEntry.create_indexes
fixture_members = {}
%w[admin board_member resource_manager member].each do |role|
  email = "paid-months-#{role}@example.com"
  member = Member.find_by(email: email) || Member.new(email: email)
  member.skip_email_deliverability_validation = true
  member.assign_attributes(firstname: 'Paid Months', lastname: role, role: role, status: 'activeMember',
    password: 'fixture-password123', expirationTime: 1.month.from_now.to_i * 1000,
    member_contract_signed_date: Date.current, address_street: '12 Example Street',
    address_city: 'Test Town', address_state: 'NH', address_postal_code: '03101')
  member.save!
  member.update_permissions(billing: true)
  MembershipPaidCreditEntry.where(member_id: member.id).delete_all
  # Controlled fixture state, intentionally separate from live accounting writes.
  Member.collection.find(_id: member.id).update_one('$set' => {
    continuous_paid_membership_months: role == 'member' ? 11 : 0,
    continuous_paid_membership_balance: BSON::Decimal128.new(role == 'member' ? '11' : '0'),
    continuous_paid_membership_revision: role == 'member' ? 7 : 0,
    continuous_paid_membership_estimated: true
  })
  fixture_members[role] = { id: member.id.to_s, email: email }
end
puts "PAID_MEMBERSHIP_FIXTURE=#{JSON.generate(fixture_members)}"
