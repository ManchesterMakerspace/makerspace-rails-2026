module EventbriteRecord
  extend ActiveSupport::Concern
  included do
    include Mongoid::Document
    include Mongoid::Timestamps
    field :organization_id, type: String
    field :eventbrite_id, type: String
    field :provider_changed_at, type: Time
    field :synced_at, type: Time
    field :invalidated_at, type: Time
    field :invalidation_reason, type: String
    validates :organization_id, :eventbrite_id, presence: true
    index({ organization_id: 1, eventbrite_id: 1 }, unique: true)
  end
end
