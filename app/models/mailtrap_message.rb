class MailtrapMessage
  include Mongoid::Document
  include Mongoid::Timestamps::Created

  store_in collection: 'mailtrap_messages'

  field :message_id,   type: String
  field :subject,      type: String
  field :email,        type: String
  field :mailer_class, type: String
  field :action,       type: String
  field :member_id,    type: BSON::ObjectId

  index({ message_id: 1 }, { unique: true, sparse: true })
  index({ member_id:  1 })
  index({ email:      1 })
  index({ created_at: 1 })

  validates :message_id, presence: true
  validates :subject,    presence: true
  validates :email,      presence: true
end
