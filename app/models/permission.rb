class Permission
  include Mongoid::Document

  field :name, type: String
  field :enabled, type: Boolean, default: false

  validates :name, presence: true

  belongs_to :member

  index({ member_id: 1, name: 1 }, { unique: true })
  after_save { MongoCache.invalidate("permissions", "member_permissions/#{member_id}") }
  after_destroy { MongoCache.invalidate("permissions", "member_permissions/#{member_id}") }

  def self.list_permissions
    MongoCache.fetch("permissions/list", dependencies: ["permissions"]) do
      distinct(:name).to_a
    end
  end
end
