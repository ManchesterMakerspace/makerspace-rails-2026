class NfcCardEnrollment
  include Mongoid::Document
  field :_id, type: String
  field :attempt_id, type: String
  field :state, type: String, default: 'idle'
  field :fence, type: Integer, default: 0
  field :revision, type: Integer, default: 1
  field :actor_id, type: BSON::ObjectId
  field :member_id, type: BSON::ObjectId
  field :card_id, type: BSON::ObjectId
  field :assignment_version, type: Integer
  field :workflow, type: String
  field :sealed, type: Hash
  field :created_at, type: Time
  field :completed_at, type: Time
  index({ attempt_id: 1 }, unique: true, partial_filter_expression: { attempt_id: { '$type' => 'string' } })
  index({ actor_id: 1, member_id: 1, state: 1 })

  # Every assignment writer touches this document, including legacy UID imports.
  def self.lock!(uid)
    row = where(id: uid).first || create!(id: uid)
    row.inc(fence: 1)
    row
  end
end
