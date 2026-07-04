class ApplicationController < ActionController::Base
  include ApplicationHelper
  include ::Error::ErrorHandler
  include SlackService
  include SetCurrentRequestDetails

  protect_from_forgery with: :exception
  after_action :set_csrf_cookie_for_ng
  after_action :log_not_found_file_lookup_context, if: -> { response.status == 404 }
  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :filter_requests
  before_action :allow_only_html_requests, only: [:application]

  def application
    render "layouts/application"
  end

  def set_csrf_cookie_for_ng
    cookies['XSRF-TOKEN'] = form_authenticity_token if protect_against_forgery?
  end

  protected

  def log_not_found_file_lookup_context
    return if @logged_not_found_file_lookup_context

    @logged_not_found_file_lookup_context = true
    Rails.logger.info(
      "[404 file lookup] requested_path=#{request.path} " \
      "translated_locations=#{translated_file_lookup_locations.join(', ')}"
    )
  rescue => e
    Rails.logger.warn("Failed to log 404 file lookup context: #{e.message}")
  end

  def translated_file_lookup_locations
    requested_path = request.path.to_s
    relative_path = requested_path.delete_prefix('/')
    clean_relative_path = Pathname.new(relative_path).cleanpath.to_s
    clean_relative_path = '' if clean_relative_path.start_with?('..')

    lookup_roots = [Rails.root.join('public')]
    if Rails.application.config.respond_to?(:assets)
      lookup_roots += Array(Rails.application.config.assets.paths)
    end

    lookup_roots.map { |root| File.join(root.to_s, clean_relative_path) }.uniq
  end

  def allow_only_html_requests
    if params[:format] && params[:format] != "html"
      render plain: "Not Found", status: 404
    end
  end

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up, keys: [:firstname, :lastname])
  end

  # In Rails 4.2 and above
  def verified_request?
    super || valid_authenticity_token?(session, request.headers['X-XSRF-TOKEN'])
  end

  def is_admin?
    current_member.try(:role) == 'admin'
  end

  def is_resource_manager?
    current_member.try(:role) == 'resource_manager'
  end

  def is_board_member?
    current_member.try(:role) == 'board_member'
  end

  def is_privileged?
    is_admin? || is_board_member? || is_resource_manager?
  end

  def is_valid_checkout_approver?
    current_member.try(:valid_for_checkout_request?) && CheckoutApprover.exists?(member_id: current_member.id)
  end

  def can_view_disabled_tools?
    is_admin? || is_board_member? || is_resource_manager?
  end

  def filter_requests
    if params[:format] && (/html|json/ =~ params[:format]).nil?
      raise Error::NotFound.new
    end
  end
end
