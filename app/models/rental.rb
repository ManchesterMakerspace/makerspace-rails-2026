class Rental
  include Mongoid::Document
  include Mongoid::Search
  include InvoiceableResource
  include Service::SlackConnector
  include ActiveModel::Serializers::JSON
  include Publishable

  STATUSES = %w[pending pending_agreement active vacating cancelled denied agreement_denied].freeze

  belongs_to :member

  field :number
  field :description
  field :expiration,           type: Integer
  field :subscription_id,      type: String
  field :contract_signed_date, type: Date
  field :notes,                type: String
  field :status,               type: String, default: "active"
  field :rental_spot_id,       type: String

  search_in :number, member: %i[firstname lastname email]

  after_destroy :publish_destroy

  validates :number, presence: true, uniqueness: {
    conditions: -> { where(:status.in => ["active", "pending", "pending_agreement", "vacating"]) }
  }
  validates :status, inclusion: { in: STATUSES }

  def rental_spot
    return nil if rental_spot_id.blank?
    RentalSpot.find(rental_spot_id)
  rescue
    nil
  end

  def send_renewal_slack_message(current_user = nil)
    slack_user = SlackUser.find_by(member_id: member_id)
    ::Service::SlackConnector.send_slack_message(get_renewal_slack_message, slack_user.slack_id) unless slack_user.nil?
    ::Service::SlackConnector.send_slack_message(get_renewal_slack_message(current_user), ::Service::SlackConnector.members_relations_channel)
  end

  def self.search(searchTerms, criteria = Mongoid::Criteria.new(Rental))
    criteria.full_text_search(searchTerms)
  end

  def remove_subscription
    self.update_attributes!({ subscription_id: nil })
  end

  def contract_on_file=(onFile)
    if onFile && contract_signed_date.nil?
      self.update_attributes!({ contract_signed_date: Date.today })
    elsif !onFile
      self.update_attributes!({ contract_signed_date: nil })
    end
  end

  protected

  def expiration_attr
    :expiration
  end

  def base_slack_message
    "#{self.member ? "#{self.member.fullname}'s rental of " : ""} # #{self.number}"
  end

  def publish_destroy
    publish(:destroy)
  end
end
