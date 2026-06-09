class MailtrapEvent
  include Mongoid::Document
  include Mongoid::Timestamps

  store_in collection: 'mailtrap_events'

  field :email,               type: String
  field :status,              type: String
  field :event,               type: String
  field :event_id,            type: String
  field :message_id,          type: String
  field :occurred_at,         type: Time
  field :sending_stream,      type: String
  field :sending_domain_name, type: String
  field :timestamp,           type: Integer
  field :member_id,           type: BSON::ObjectId
  field :raw_payload,         type: Hash

  # Join to MailtrapMessage — populated at webhook receipt time when
  # a matching send-time record exists.
  field :mailtrap_message_id, type: BSON::ObjectId

  index({ member_id:  1 })
  index({ event_id:   1 }, { unique: true, sparse: true })
  index({ message_id: 1 })
  index({ occurred_at: 1 })

  belongs_to :mailtrap_message, optional: true, class_name: 'MailtrapMessage',
             primary_key: :id, foreign_key: :mailtrap_message_id
end
