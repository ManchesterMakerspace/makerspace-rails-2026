require 'digest'

class ReservationAnnouncementLease < SlackDeliveryLease
  def self.with(identity, &block)
    super("reservation_announcement:lease:#{Digest::SHA256.hexdigest(identity)}", &block)
  end
end
