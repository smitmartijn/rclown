class Health::AccountStatus
  def initialize(account, settings:, now:)
    @account, @settings, @now = account, settings, now
  end

  def call
    runs = @account.discovery_runs.where(preview: false).order(created_at: :desc, id: :desc)
    latest = runs.first
    successes = runs.success.where.not(finished_at: nil).limit(10).to_a
    success = successes.first
    duration = successes.filter_map { |run| (run.finished_at - run.started_at).ceil if run.started_at }.max || 0
    due_at = success ? [ success.created_at + @account.discovery_interval_minutes.minutes, success.finished_at ].max : @account.activated_at
    overdue_at = due_at && due_at + @settings.grace_seconds + duration
    result = runs.where(status: %w[success partial failed]).first
    bucket_issues = @account.buckets.includes(:backup).count do |bucket|
      !@account.exclusion_for(bucket.bucket_name) && bucket.backup&.enabled? != false && (!bucket.available? || bucket.last_error.present?)
    end

    status, code = if !@account.active? || !@account.discovery_enabled?
      [ "healthy", @account.active? ? "discovery_paused" : "draft" ]
    elsif latest&.running?
      [ "healthy", "discovery_running" ]
    elsif result&.failed?
      [ "error", "discovery_failed" ]
    elsif result&.partial? || bucket_issues.positive?
      [ "warning", "buckets_need_attention" ]
    elsif overdue_at && @now > overdue_at
      [ "warning", "discovery_overdue" ]
    else
      [ "healthy", "within_schedule" ]
    end
    { id: @account.id, name: @account.name, source_provider_id: @account.source_provider_id,
      status: status, code: code, latest_run_status: latest&.status, overdue_at: overdue_at,
      last_success_at: success&.finished_at, buckets_needing_attention: bucket_issues }
  end
end
