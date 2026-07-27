class SlackUser
  include Mongoid::Document
  include SanitizesUserInput
  belongs_to :member, optional: true

  field :slack_email, type: String
  field :slack_id, type: String
  field :name, type: String
  field :real_name, type: String

  index({ member_id: 1 }, { sparse: true })
  index({ slack_id: 1 }, { unique: true, sparse: true })

  after_save { MongoCache.invalidate("slack_users", "canvas_managers") }
  after_destroy { MongoCache.invalidate("slack_users", "canvas_managers") }

  attr_readonly *fields.keys
end
