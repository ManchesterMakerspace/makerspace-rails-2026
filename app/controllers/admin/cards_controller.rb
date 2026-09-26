class Admin::CardsController < AdminController
  before_action :active_nfc_operator!, only: [:lookup, :destroy]
  before_action { response.set_header('Cache-Control', 'private, no-store') }
  rescue_from CardManagement::Conflict do |error|
    render json: { error: error.message }, status: :conflict
  end
  rescue_from CardManagement::Unavailable do |error|
    render json: { error: error.message }, status: :service_unavailable
  end

  def lookup
    uid = params.require(:uid)
    unless uid.is_a?(String) && uid.match?(/\A(?:[0-9A-F]{2})+\z/)
      return render json: { error: 'UID must be uppercase hexadecimal ASCII byte pairs.' }, status: :unprocessable_entity
    end
    cards = Card.where(uid: uid).limit(2).to_a
    raise Error::NotFound.new if cards.empty?
    raise CardManagement::Conflict, 'Duplicate UID records require administrator repair.' if cards.length > 1
    render json: CardManagement.snapshot(cards.first)
  end

  def destroy
    CardManagement.release!(params[:id], params.require(:version), current_member)
    head :no_content
  end

  def new
    @card = Card.new()
    reject = RejectionCard.where({holder: nil, timeOf: {'$gt' => (Date.today - 1.day)}}).sort(timeOf: 1).last
    @card.uid = reject.uid if !!reject
    render json: @card, adapter: :attributes and return
  end

  def create
    if params[:source] == 'nfc'
      active_nfc_operator!
      unless params[:uid].is_a?(String) && params[:uid].match?(/\A(?:[0-9A-F]{2})+\z/)
        return render json: { error: 'UID must be uppercase hexadecimal ASCII byte pairs.' }, status: :unprocessable_entity
      end
    end
    @card = CardManagement.assign!(create_card_params, current_member)

    render json: @card, adapter: :attributes and return
  end

  def index
    member = Member.find(card_query_params[:member_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: card_query_params[:member_id] }) if member.nil?
    @cards = Card.where(member: member)
    render json: @cards, adapter: :attributes and return
  end

  def update
    @card = Card.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Card, { id: params[:id] }) if @card.nil?
    before = @card.attributes.dup
    @card.update_attributes!(update_card_params)

    ::Service::AuditLogger.log(
      log_type:        'member',
      event_type:      'card_updated',
      resource_type:   'Card',
      resource_id:     @card.id,
      actor:           current_member,
      subject:         @card.member,
      field_changes:   @card.previous_changes,
      before_snapshot: before,
      after_snapshot:  @card.attributes
    )

    render json: @card, adapter: :attributes and return
  end

  private
  def active_nfc_operator!
    raise Error::Forbidden.new unless current_member.fully_active_unexpired?
  end

  def create_card_params
    params.require([:member_id, :uid])
    params.permit(:member_id, :uid)
  end

  def update_card_params
    params.require(:card_location)
    params.permit(:card_location)
  end

  def card_query_params
    params.require(:member_id)
    params.permit(:member_id)
  end
end
