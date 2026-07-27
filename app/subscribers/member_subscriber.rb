module MemberSubscriber
  extend self

  def subscribe
    Member.subscribe(:create) do |event|
      MemberProvisioningJob.perform_later(event[:model].id.to_s)
    end

    Member.subscribe(:billing_info_changed) do |event|
      MemberBillingSyncJob.perform_later(event[:model].id.to_s)
    end

    Member.subscribe(:destroy) do |event|
      member = event[:model]
      MemberDestroyCleanupJob.perform_later(
        member.subscription_id,
        member.rentals.pluck(:id).map(&:to_s),
        member.fullname
      )
    end
  end
end
