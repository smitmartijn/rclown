class Health::BackupStatus
  def initialize(backup, settings:, now:)
    @backup, @settings, @now = backup, settings, now
  end

  def call
    runs = @backup.runs.where(dry_run: false).order(created_at: :desc, id: :desc)
    latest = runs.first
    running = runs.running.first
    successes = runs.successful.where.not(finished_at: nil).limit(10).to_a
    success = successes.first
    duration = successes.filter_map { |run| run.duration&.ceil }.select { |seconds| seconds >= 0 }.max || 0
    interval = @backup.weekly? ? 1.week : 1.day
    due_at = success ? [ success.created_at + interval, success.finished_at ].max : @backup.created_at
    overdue_at = due_at + @settings.grace_seconds + duration
    last_result = runs.where(status: %w[success failed]).first

    status, state, code = if !@backup.health_monitored?
      [ "healthy", @backup.enabled? ? "excluded" : "disabled", "not_monitored" ]
    elsif running
      [ "healthy", running.stopping? ? "stopping" : "running", "backup_running" ]
    elsif @backup.account_backup_bucket && !@backup.account_backup_bucket.available?
      [ "warning", "on_hold", "source_bucket_missing" ]
    elsif last_result&.failed?
      [ "error", "failed", "backup_failed" ]
    elsif @now > overdue_at
      [ "warning", "missed", "backup_overdue" ]
    else
      [ "healthy", latest&.pending? ? "pending" : "scheduled", "within_schedule" ]
    end

    { id: @backup.id, name: @backup.name, status: status, state: state, code: code,
      monitored: @backup.health_monitored?, schedule: @backup.schedule,
      source_storage_id: @backup.source_storage_id, destination_storage_id: @backup.destination_storage_id,
      expected_next_run_at: due_at, overdue_at: overdue_at, expected_duration_seconds: duration,
      last_success_at: success&.finished_at, latest_run: run_json(running || latest),
      last_result: run_json(last_result), connectivity: connectivity }
  end

  private
    def run_json(run)
      return nil unless run
      { id: run.id, status: run.status, created_at: run.created_at, started_at: run.started_at,
        finished_at: run.finished_at, duration_seconds: run.duration&.to_i }
    end

    def connectivity
      return { status: "healthy", code: "not_monitored", checked_at: nil, results: {} } unless @backup.health_monitored?

      check = @backup.health_check
      code = if !check&.checked_at
        "not_checked"
      elsif check.configuration_digest != BackupHealthCheck.configuration_digest(@backup)
        "configuration_changed"
      elsif check.checked_at < @now - @settings.check_max_age_seconds
        "check_stale"
      end
      if code
        # New backups have the same startup grace as their first scheduled run.
        status = @now <= @backup.created_at + @settings.grace_seconds && code == "not_checked" ? "healthy" : "warning"
        return { status: status, code: code, checked_at: check&.checked_at, results: {} }
      end

      results = check.results.slice("source", "destination")
      complete = %w[source destination].all? { |role| %w[healthy error].include?(results.dig(role, "status")) }
      status = complete ? Health::Report.worst(results.values.map { |value| value["status"] }) : "warning"
      { status: status, code: complete ? "checked" : "incomplete_check", checked_at: check.checked_at, results: complete ? results : {} }
    end
end
