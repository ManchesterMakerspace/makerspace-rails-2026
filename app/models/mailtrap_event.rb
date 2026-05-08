class MailtrapEvent
  include Mongoid::Document
  include Mongoid::Attributes::Dynamic
  include Mongoid::Timestamps::Created

  store_in collection: "mailtrap"

  field :member_id, type: BSON::ObjectId
  field :email, type: String
  field :status, type: String
  field :occurred_at, type: Time
  field :event, type: String
  field :event_id, type: String
  field :message_id, type: String
  field :response, type: String
  field :sending_stream, type: String
  field :sending_domain_name, type: String
  field :timestamp, type: Integer
  field :raw_payload, type: Hash
end
