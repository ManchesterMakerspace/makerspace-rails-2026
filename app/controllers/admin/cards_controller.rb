class Admin::CardsController < AdminController

  def new
    @card = Card.new()
    reject = RejectionCard.where({holder: nil, timeOf: {'$gt' => (Date.today - 1.day)}}).sort(timeOf: 1).last
    @card.uid = reject.uid if !!reject
    render json: @card, adapter: :attributes and return
  end

  def create
    @card = Card.new(create_card_params)
    raise Error::NotFound.new() unless @card.member

    cards = @card.member.access_cards.select { |c| (c.validity != 'lost') && (c.validity != 'stolen') && (c != @card)}
    cards.each { |card| card.invalidate }

    @card.save!
    rejection_card = RejectionCard.find_by(uid: @card.uid)
    rejection_card.update_attributes!(holder: @card.holder) unless rejection_card.nil?

    ::Service::AuditLogger.log(
      log_type:       'member',
      event_type:     'card_assigned',
      resource_type:  'Card',
      resource_id:    @card.id,
      actor:          current_member,
      subject:        @card.member,
      after_snapshot: { uid: @card.uid, member_id: @card.member_id.to_s },
      slack_channel:  ::Service::SlackConnector.logs_channel
    )

    render json: @card, adapter: :attributes and return
  end

  def index
    member = Member.find(card_query_params[:member_id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: card_query_params[:member_id] }) if member.nil?
    @cards = Card.where(member: member)
    render json: @cards, adapter: :attributes and return
  end

  # Looks up a physical access card without exposing the cards collection to
  # clients. This is used by trusted board/admin NFC readers.
  def by_uid
    uid = normalize_uid(params.require(:uid))
    @card = Card.where(uid: uid).first
    raise ::Mongoid::Errors::DocumentNotFound.new(Card, { uid: uid }) if @card.nil?

    render json: @card, adapter: :attributes and return
  end

  def destroy
    card = Card.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(Card, { id: params[:id] }) if card.nil?
    member = card.member
    event_type = removal_event_type(card, member)
    raise ::Error::UnprocessableEntity.new('Only lost fobs or fobs assigned to expired/revoked members can be removed') unless event_type

    before = card.attributes.dup
    member.unset(:cardID) if member.cardID.to_s == card.uid.to_s
    card.destroy!

    ::Service::AuditLogger.log(
      log_type: 'member',
      event_type: event_type,
      resource_type: 'Card',
      resource_id: card.id,
      actor: current_member,
      subject: member,
      before_snapshot: before,
      after_snapshot: nil,
      message_details: "UID #{card.uid} removed"
    )

    head :no_content
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

  def normalize_uid(uid)
    uid.to_s.upcase.gsub(/[:\-\s]/, '')
  end

  def removal_event_type(card, member)
    return 'lost_card_forgotten' if card.validity == 'lost'
    return 'card_unassigned' if %w[expired revoked].include?(member.status) || %w[expired revoked].include?(card.validity)
  end
end
