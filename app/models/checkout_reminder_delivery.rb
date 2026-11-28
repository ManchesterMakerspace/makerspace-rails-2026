# Pending Slack posts only. Removed after all participating requests have their
# receipt. The UUID is also Slack's client_msg_id, including on recovery.
class CheckoutReminderDelivery
  include Mongoid::Document

  field :_id, type: String, default: -> { SecureRandom.uuid }
  field :member_id, type: BSON::ObjectId
  field :day, type: String
  field :shop_id, type: BSON::ObjectId
  field :request_ids, type: Array
  field :number, type: Integer
  field :final_warning, type: Boolean
  field :channel, type: String
  field :destination_mode, type: String
  field :attempted_at, type: Time
  field :declines_on, type: String
  field :member_name, type: String
  field :shop_name, type: String
  field :posted_channel, type: String
  field :ts, type: String
end
