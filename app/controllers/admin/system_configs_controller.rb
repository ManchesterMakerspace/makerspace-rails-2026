class Admin::SystemConfigsController < AdminController

  # Keys that can be toggled as boolean flags
  FLAG_KEYS = [
    SystemConfig::SLACK_SYNC_ENABLED,
    'volunteer_bounty_token_enabled',
    'require_totp_admin',
    'require_totp_board',
    'require_totp_rm',
  ].freeze

  # Keys that can be updated as plain string values
  SETTING_KEYS = [
    # Slack channels
    'slack_channel_treasurer',
    'slack_channel_rm',
    'slack_channel_admin',
    'slack_channel_logs',
    'volunteer_pending_slack_channel',
    # Volunteer settings
    'volunteer_credits_per_discount',
    'volunteer_max_discounts_per_year',
    'volunteer_discount_id',
    'volunteer_task_max_credit',
    'volunteer_bounty_token',
    'volunteer_rolling_days',
    'volunteer_leaderboard_top',
    # Security settings
    'devise_timeout_minutes',
    SystemConfig::MONGO_CACHE_TTL_HOURS,
  ].freeze

  ALL_EDITABLE_KEYS = (FLAG_KEYS + SETTING_KEYS).freeze

  # GET /api/admin/system_configs
  def index
    flags = {
      slack_sync_enabled:             SystemConfig.enabled?(SystemConfig::SLACK_SYNC_ENABLED),
      volunteer_bounty_token_enabled: SystemConfig.enabled?('volunteer_bounty_token_enabled'),
      require_totp_admin:             SystemConfig.enabled?('require_totp_admin'),
      require_totp_board:             SystemConfig.enabled?('require_totp_board'),
      require_totp_rm:                SystemConfig.enabled?('require_totp_rm'),
    }

    jobs = SystemConfig::JOB_KEYS.map do |job_key, task_name|
      status = SystemConfig.job_status(job_key)
      {
        key:             job_key,
        task:            task_name,
        last_run_at:     status&.dig(:last_run_at),
        last_run_status: status&.dig(:last_run_status)
      }
    end

    slack = {
      slack_channel_treasurer:          SystemConfig.get('slack_channel_treasurer')          || 'treasurer',
      slack_channel_rm:                 SystemConfig.get('slack_channel_rm')                 || 'members_relations',
      slack_channel_admin:              SystemConfig.get('slack_channel_admin')               || 'general',
      slack_channel_logs:               SystemConfig.get('slack_channel_logs')               || 'interface-logs',
      volunteer_pending_slack_channel:  SystemConfig.get('volunteer_pending_slack_channel')  || 'general',
    }

    volunteer = {
      volunteer_credits_per_discount:   SystemConfig.get('volunteer_credits_per_discount')   || '8',
      volunteer_max_discounts_per_year: SystemConfig.get('volunteer_max_discounts_per_year') || '2',
      volunteer_discount_id:            SystemConfig.get('volunteer_discount_id')             || '',
      volunteer_task_max_credit:        SystemConfig.get('volunteer_task_max_credit')         || '2.0',
      volunteer_bounty_token:           SystemConfig.get('volunteer_bounty_token')            || '',
      volunteer_rolling_days:           SystemConfig.get('volunteer_rolling_days')           || '90',
      volunteer_leaderboard_top:        SystemConfig.get('volunteer_leaderboard_top')        || '10',
    }

    totp = {
      require_totp_admin: SystemConfig.enabled?('require_totp_admin'),
      require_totp_board: SystemConfig.enabled?('require_totp_board'),
      require_totp_rm:    SystemConfig.enabled?('require_totp_rm'),
    }

    security = {
      devise_timeout_minutes: SystemConfig.get('devise_timeout_minutes') || '30',
      mongo_cache_ttl_hours: SystemConfig.get(SystemConfig::MONGO_CACHE_TTL_HOURS) || '8',
    }

    render json: {
      flags:     flags,
      jobs:      jobs,
      slack:     slack,
      volunteer: volunteer,
      totp:      totp,
      security:  security,
    }, status: :ok
  end

  # PUT /api/admin/system_configs/update_flag
  # Toggle a boolean feature flag
  def update_flag
    key   = params[:key]
    value = params[:value]

    unless FLAG_KEYS.include?(key)
      render json: { error: "Unknown flag key: #{key}" }, status: :unprocessable_content and return
    end

    old_value = SystemConfig.enabled?(key).to_s
    SystemConfig.set(key, value)

    Service::AuditLogger.log(
      log_type:      'portal',
      event_type:    'portal_setting_changed',
      resource_type: 'SystemConfig',
      resource_id:   BSON::ObjectId.new, # SystemConfig has no document ID — generate one for the log
      actor:         current_member,
      field_changes: { key => [old_value, value.to_s] },
      slack_channel: ::Service::SlackConnector.logs_channel
    )

    render json: { key: key, value: value }, status: :ok
  end

  # PUT /api/admin/system_configs/update_setting
  # Update a plain string setting value.
  # Special case: volunteer_discount_id changes post Slack notifications to
  # the logs and treasurer channels for full audit transparency.
  def update_setting
    key   = params[:key]
    value = params[:value].to_s.strip

    unless SETTING_KEYS.include?(key)
      render json: { error: "Unknown setting key: #{key}" }, status: :unprocessable_content and return
    end

    old_value = SystemConfig.get(key).to_s
    return unless valid_setting_value?(key, value)

    if key == 'volunteer_discount_id'
      SystemConfig.set(key, value)
      VolunteerDiscountNotificationJob.perform_later(
        old_value.presence,
        value.presence,
        current_member&.fullname || "Unknown Admin"
      )
    else
      SystemConfig.set(key, value)
    end

    # Audit log goes to logs channel for all setting changes.
    # volunteer_discount_id also posts to treasurer via notify_volunteer_discount_changed above —
    # that post is intentionally left in place for treasurer visibility.
    Service::AuditLogger.log(
      log_type:      'portal',
      event_type:    'portal_setting_changed',
      resource_type: 'SystemConfig',
      resource_id:   BSON::ObjectId.new,
      actor:         current_member,
      field_changes: { key => [old_value, value] },
      slack_channel: ::Service::SlackConnector.logs_channel
    )

    render json: { key: key, value: value }, status: :ok
  end

  # POST /api/admin/system_configs/run_job
  def run_job
    job_key = params[:key]

    unless SystemConfig::JOB_KEYS.key?(job_key)
      render json: { error: "Unknown job: #{job_key}" }, status: :unprocessable_content and return
    end

    case job_key
    when 'slack_sync'      then SlackSyncJob.perform_later
    when 'member_review'   then MemberReviewJob.perform_later
    when 'invoice_review'  then InvoiceReviewJob.perform_later
    when 'garbage_collect' then GarbageCollectJob.perform_later
    when 'db_backup'       then DatabaseBackupJob.perform_later
    when 'reservation_canvas_rebuild'
      ReservationSlackCanvasRebuildJob.perform_later
    end

    render json: { message: "#{job_key} enqueued successfully" }, status: :ok
  end

  private

  def valid_setting_value?(key, value)
    if key == SystemConfig::MONGO_CACHE_TTL_HOURS
      ttl_hours = Integer(value)
      return true if ttl_hours.between?(MongoCache::MIN_TTL_HOURS, MongoCache::MAX_TTL_HOURS)

      raise ArgumentError, "must be between 1 and 24"
    end

    return true unless key == 'devise_timeout_minutes'

    timeout_minutes = Integer(value)
    return true if timeout_minutes.positive?

    raise ArgumentError, 'must be greater than 0'
  rescue ArgumentError
    message = if key == SystemConfig::MONGO_CACHE_TTL_HOURS
      "mongo_cache_ttl_hours must be a whole number between 1 and 24"
    else
      "devise_timeout_minutes must be a positive whole number of minutes"
    end
    render json: { error: message },
           status: :unprocessable_entity
    false
  end

end
