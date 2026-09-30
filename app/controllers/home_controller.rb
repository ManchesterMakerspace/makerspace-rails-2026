class HomeController < AuthenticationController
  prepend_before_action do
    response.set_header("Cache-Control", "private, no-store")
    # Render the standard JSON error here so Warden's separate failure response
    # does not discard the private/no-store header on anonymous requests.
    raise Error::Unauthorized.new unless member_signed_in?
  end

  def show
    home = MemberHome.new(current_member)
    render json: {
      member: ActiveModelSerializers::SerializableResource.new(
        current_member, serializer: MemberSerializer, adapter: :attributes,
        resolve_slack_url: false
      ).as_json,
      slack: home.slack,
      availableCheckouts: home.available_checkouts
    }
  end
end
