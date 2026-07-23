namespace :reservations do
  desc "Backfill existing Resource Managers with all current shops"
  task backfill_resource_manager_shops: :environment do
    shop_ids = Shop.all.pluck(:id).map(&:to_s)
    Member.where(role: "resource_manager").each do |member|
      next if member.resource_manager_shop_ids.present?
      member.set(resource_manager_shop_ids: shop_ids)
    end
  end

  desc "Normalize legacy reservation status spelling from canceled to cancelled"
  task normalize_cancelled_status: :environment do
    count = Reservation.where(status: "canceled").update_all(status: "cancelled")
    puts "Updated #{count} reservation(s) to cancelled"
  end
end
