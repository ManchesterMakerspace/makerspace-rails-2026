class Admin::SystemConfigsController < AdminController

  # Keys that can be toggled as boolean flags
  FLAG_KEYS = [
    SystemConfig::SLACK_SYNC_ENABLED,
    'volunteer_bounty_token_enabled',
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
    'volunteer_discount_amount',
    'volunteer_task_max_credit',
    'volunteer_bounty_token',
  ].freeze

  ALL_EDITABLE_KEYS = (FLAG_KEYS + SETTING_KEYS).freeze

  # GET /api/admin/system_configs
  def index
    flags = {
      slack_sync_enabled:             SystemConfig.enabled?(SystemConfig::SLACK_SYNC_ENABLED),
      volunteer_bounty_token_enabled: SystemConfig.enabled?('volunteer_bounty_token_enabled'),
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
      slack_channel_treasurer:          SystemConfig.get('slack_channel_treasurer')          || ENV.fetch('SLACK_TREASURER_CHANNEL', 'treasurer'),
      slack_channel_rm:                 SystemConfig.get('slack_channel_rm')                 || ENV.fetch('SLACK_RM_CHANNEL', 'general'),
      slack_channel_admin:              SystemConfig.get('slack_channel_admin')               || ENV.fetch('SLACK_ADMIN_CHANNEL', 'general'),
      slack_channel_logs:               SystemConfig.get('slack_channel_logs')               || ENV.fetch('SLACK_LOGS_CHANNEL', 'interface-logs'),
      volunteer_pending_slack_channel:  SystemConfig.get('volunteer_pending_slack_channel')  || ENV.fetch('VOLUNTEER_PENDING_SLACK_CHANNEL', 'general'),
    }

    volunteer = {
      volunteer_credits_per_discount:   SystemConfig.get('volunteer_credits_per_discount')   || ENV.fetch('VOLUNTEER_CREDITS_PER_DISCOUNT', '8'),
      volunteer_max_discounts_per_year: SystemConfig.get('volunteer_max_discounts_per_year') || ENV.fetch('VOLUNTEER_MAX_DISCOUNTS_PER_YEAR', '2'),
      volunteer_discount_amount:        SystemConfig.get('volunteer_discount_amount')         || ENV.fetch('VOLUNTEER_DISCOUNT_AMOUNT', '0'),
      volunteer_task_max_credit:        SystemConfig.get('volunteer_task_max_credit')         || ENV.fetch('VOLUNTEER_TASK_MAX_CREDIT', '2.0'),
      volunteer_bounty_token:           SystemConfig.get('volunteer_bounty_token')            || '',
    }

    render json: {
      flags:     flags,
      jobs:      jobs,
      slack:     slack,
      volunteer: volunteer,
    }, status: :ok
  end

  # PUT /api/admin/system_configs/update_flag
  # Toggle a boolean feature flag
  def update_flag
    key   = params[:key]
    value = params[:value]

    unless FLAG_KEYS.include?(key)
      render json: { error: "Unknown flag key: #{key}" }, status: :unprocessable_entity and return
    end

    SystemConfig.set(key, value)
    render json: { key: key, value: value }, status: :ok
  end

  # PUT /api/admin/system_configs/update_setting
  # Update a plain string setting value
  def update_setting
    key   = params[:key]
    value = params[:value].to_s.strip

    unless SETTING_KEYS.include?(key)
      render json: { error: "Unknown setting key: #{key}" }, status: :unprocessable_entity and return
    end

    SystemConfig.set(key, value)
    render json: { key: key, value: value }, status: :ok
  end

  # POST /api/admin/system_configs/run_job
  def run_job
    job_key = params[:key]

    unless SystemConfig::JOB_KEYS.key?(job_key)
      render json: { error: "Unknown job: #{job_key}" }, status: :unprocessable_entity and return
    end

    case job_key
    when 'slack_sync'      then SlackSyncJob.perform_later
    when 'member_review'   then MemberReviewJob.perform_later
    when 'invoice_review'  then InvoiceReviewJob.perform_later
    when 'garbage_collect' then GarbageCollectJob.perform_later
    when 'db_backup'       then DatabaseBackupJob.perform_later
    end

    render json: { message: "#{job_key} enqueued successfully" }, status: :ok
  end
end
