# A primary member's invitation to a second adult to join their household. The link carries a random token; only its
# SHA-256 digest is stored, so a database read cannot be turned back into a working link. An invitation takes one of the
# household's seats from the moment it is sent until it is accepted, revoked or has expired, so a household can never
# have more adults than its plan covers.
class HouseholdInvitation
  include Mongoid::Document
  include Mongoid::Timestamps

  VALID_DAYS = 14
  STATUSES = %w[pending accepted revoked].freeze

  field :group_id,           type: BSON::ObjectId
  field :invited_email,      type: String
  field :token_digest,       type: String
  field :status,             type: String, default: 'pending'
  field :expires_at,         type: Time
  field :sent_count,         type: Integer, default: 0
  field :last_sent_at,       type: Time
  field :invited_by_id,      type: BSON::ObjectId
  field :accepted_member_id, type: BSON::ObjectId
  field :accepted_at,        type: Time
  field :revoked_at,         type: Time

  validates :group_id, :invited_email, :token_digest, :expires_at, presence: true
  validates :status, inclusion: { in: STATUSES }

  index({ token_digest: 1 }, { unique: true })
  index({ group_id: 1, status: 1 })
  index({ invited_email: 1, status: 1 })

  before_validation { self.invited_email = invited_email.to_s.strip.downcase }

  # Pending and not yet expired: these hold a seat and their link works.
  scope :outstanding, -> { where(status: 'pending', :expires_at.gt => Time.current) }

  def self.digest(raw_token)
    Digest::SHA256.hexdigest(raw_token.to_s)
  end

  def self.find_by_token(raw_token)
    return nil if raw_token.blank?

    where(token_digest: digest(raw_token)).first
  end

  # Sets a new link (the old one stops working) and the 14 day window, and returns the token to put in the email. The
  # token itself is never stored.
  def issue_token!
    raw = SecureRandom.urlsafe_base64(32)
    self.token_digest = self.class.digest(raw)
    self.expires_at = VALID_DAYS.days.from_now
    self.sent_count = sent_count.to_i + 1
    self.last_sent_at = Time.current
    self.status = 'pending'
    save!
    raw
  end

  def expired?
    status == 'pending' && expires_at <= Time.current
  end

  def open?
    status == 'pending' && !expired?
  end

  # pending, expired, accepted or revoked
  def display_status
    expired? ? 'expired' : status
  end

  def group
    Group.where(id: group_id).first
  end

  def invited_by
    Member.where(id: invited_by_id).first
  end
end
