class Admin::ToolCheckoutsController < ApplicationController
  include Service::SlackConnector
  before_action :authenticate_member!
  before_action :authorize_index, only: [:index]
  before_action :find_checkout, only: [:update, :destroy]
  before_action :authorize_approver, only: [:create, :destroy]

  def index
    checkouts = ToolCheckout.all

    # Filter by member, tool, shop, active status
    checkouts = checkouts.where(member_id: params[:member_id]) if params[:member_id].present?
    checkouts = checkouts.where(tool_id: params[:tool_id]) if params[:tool_id].present?
    checkouts = checkouts.where(revoked_at: nil) if params[:active] == "true"
    checkouts = checkouts.where(:revoked_at.ne => nil) if params[:active] == "false"

    # Filter by shop — join through tool
    if params[:shop_id].present?
      tool_ids = Tool.where(shop_id: params[:shop_id]).pluck(:id)
      checkouts = checkouts.where(:tool_id.in => tool_ids)
    end

    unless is_admin? || is_board_member?
      ordinary_tool_ids = CheckoutApprover.allowed_tool_ids_for_member(current_member.id)
      authorized_tools = Tool.any_of(
        { :shop_id.in => managed_shop_ids },
        { :id.in => ordinary_tool_ids, :disabled.ne => true }
      )
      checkouts = checkouts.where(:tool_id.in => authorized_tools.pluck(:id))
    end

    checkouts = checkouts.order_by(checked_out_at: :desc).to_a
    render json: checkouts, each_serializer: ToolCheckoutSerializer, adapter: :attributes, scope: current_member,
      checkout_context: CheckoutReadContext.for_checkouts(checkouts, current_member)
  end

  # POST /api/admin/tool_checkouts/lookup_card  { tool_id, uid }
  #
  # Turns a fob tapped on the approver's phone into the member it belongs to and
  # whether that member can be checked out on this tool. Nothing is created; the
  # approver confirms and then posts the checkout. Allowed for anyone who can
  # approve checkouts for THIS tool (admin/board, the shop's resource manager, an
  # assigned approver), so unlike /admin/cards/lookup it is not admin/board only,
  # and it returns only what is needed to confirm the person. A POST keeps the UID
  # out of request URLs and logs.
  def lookup_card
    response.set_header("Cache-Control", "private, no-store")
    tool = Tool.find(params.require(:tool_id))
    raise ::Error::NotFound.new unless tool
    raise ::Error::Forbidden.new("You are not authorized to approve checkouts for this tool") unless can_approve_checkout_for_tool?(tool)

    uid = params.require(:uid)
    unless uid.is_a?(String) && uid.match?(/\A(?:[0-9A-F]{2})+\z/)
      raise ::Error::UnprocessableEntity.new("UID must be uppercase hexadecimal ASCII byte pairs.")
    end
    cards = Card.where(uid: uid).limit(2).to_a
    raise ::Error::NotFound.new if cards.empty?
    raise ::Error::Conflict.new("Duplicate UID records require administrator repair.") if cards.length > 1

    # A fob reported lost or stolen must not identify its member to anyone.
    if %w[lost stolen].include?(cards.first.validity)
      raise ::Error::UnprocessableEntity.new("This fob has been reported lost or stolen and cannot be used.")
    end
    member = cards.first.member
    raise ::Error::NotFound.new unless member

    render json: CheckoutCardPreview.build(member: member, tool: tool, actor: current_member)
  end

  def create
    tool = Tool.find(checkout_params[:tool_id])
    raise Error::UnprocessableEntity.new("Tool unavailable") unless tool
    # A fob tap identifies the member by what they hold, so an approver must not be able to
    # sign off their own fob. (The search path is unchanged.)
    if sign_off_source == "fob" && checkout_params[:member_id].to_s == current_member.id.to_s
      raise Error::UnprocessableEntity.new(CheckoutCardPreview::SELF_CHECKOUT_ERROR)
    end
    checkout = CheckoutCreation.create!(actor_id: current_member.id,
      member_id: checkout_params[:member_id], tool_id: tool.id, shop_id: tool.shop_id, source: sign_off_source)
    # checkout.as_json(serializer:, adapter:, scope:) silently ignores those
    # options -- as_json doesn't understand the ActiveModelSerializers render
    # API, so this was dumping raw snake_case Mongoid attributes instead of
    # the serialized response.
    payload = ActiveModelSerializers::SerializableResource.new(checkout, serializer: ToolCheckoutSerializer,
      adapter: :attributes, scope: current_member).as_json.merge(unmet_prerequisites: [])
    render json: payload
  end

  def update
    # Only allow updating revocation fields
    if update_params[:revoked_at] || update_params[:revocation_reason]
      was_active = @checkout.revoked_at.nil?
      if was_active && update_params[:revoked_at].present?
        CheckoutApproverMutationLock.with(member_id: @checkout.member_id) do
          CheckoutMutationLock.with(member_id: @checkout.member_id, tool_id: @checkout.tool_id) do
            @checkout.reload
            @checkout.approver_mutation_lock_held = true
            @checkout.update_attributes!(update_params.merge(revoked_by_id: current_member.id))
          end
        end
      else
        @checkout.update_attributes!(update_params)
      end
    end
    render json: @checkout, serializer: ToolCheckoutSerializer, adapter: :attributes, scope: current_member
  end

  def destroy
    reason = params[:revocation_reason].presence
    raise ::Error::UnprocessableEntity.new("Revocation reason is required") unless reason

    CheckoutApproverMutationLock.with(member_id: @checkout.member_id) do
      CheckoutMutationLock.with(member_id: @checkout.member_id, tool_id: @checkout.tool_id) do
        @checkout.reload
        @checkout.approver_mutation_lock_held = true
        @checkout.update_attributes!(revoked_at: Time.now, revocation_reason: reason, revoked_by_id: current_member.id)
      end
    end

    render json: @checkout, serializer: ToolCheckoutSerializer, adapter: :attributes, scope: current_member
  end

  private

  def checkout_params
    params.require([:member_id, :tool_id])
    params.permit(:member_id, :tool_id, :source)
  end

  # How the approver identified the member: by fob tap ("fob"), or the default.
  def sign_off_source
    checkout_params[:source] == "fob" ? "fob" : "portal"
  end

  def update_params
    params.permit(:revoked_at, :revocation_reason)
  end

  def find_checkout
    @checkout = ToolCheckout.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(ToolCheckout, { id: params[:id] }) if @checkout.nil?
  end

  def authorize_index
    raise ::Error::Forbidden.new unless is_admin? || is_board_member? ||
      managed_shop_ids.present? || is_valid_checkout_approver?
  end

  # Admin/board can approve anything. RMs are privileged only in their assigned
  # shops; elsewhere they follow the exact same rules as ordinary approvers.
  def authorize_approver
    tool = @checkout.try(:tool) || Tool.find(params[:tool_id])
    return if can_approve_checkout_for_tool?(tool)

    raise ::Error::Forbidden.new("You are not authorized to approve checkouts for this tool")
  end

end
