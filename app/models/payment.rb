class Payment
  include Mongoid::Document
  include ActiveModel::Serializers::JSON

  belongs_to :member, optional: true
  after_initialize :find_member
  after_save :configure_subscription_status

  field :product
  field :firstname
  field :lastname
  field :amount, type: Float
  field :currency
  field :status
  field :payment_date
  field :payer_email
  field :address
  field :txn_id
  field :txn_type
  field :plan_id
  field :test, type: Boolean

  validates :txn_id, uniqueness: true, :allow_blank => true, :allow_nil => true

  private
  def configure_subscription_status
    return unless member

    rental_product_match = /(plot|rental|locker)/i.match(self.product)
    unless rental_product_match
      true_types = ['subscr_signup', 'subscr_payment']
      false_types = ['subscr_eot', 'subscr_cancel', 'subscr_failed']
      #use specific false types so other donations/payments don't invalidate subscription
      if true_types.include?(self.txn_type)
          self.member.subscription = true
      elsif false_types.include?(self.txn_type)
          self.member.subscription = false
      end
      self.member.save
    end
  end

  def find_member
    return if member

    # Resolve the association without saving from a read/initialization
    # callback. The controller performs the one authoritative payment save.
    self.member = Member.find_by(email: payer_email.to_s.downcase) if payer_email.present?
    self.member ||= Member.where(lastname: /\A#{Regexp.escape(lastname)}\z/i).first if lastname.present?
    self.member ||= Member.where(firstname: /\A#{Regexp.escape(firstname)}\z/i).first if firstname.present?
    if member.nil? && payer_email.present?
      previous = Payment.where(
        :member_id.ne => nil,
        payer_email: payer_email.to_s.downcase
      ).order_by(payment_date: :desc).first
      self.member = previous&.member
    end
  end
end
