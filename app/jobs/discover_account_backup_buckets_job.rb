class DiscoverAccountBackupBucketsJob < ApplicationJob
  queue_as :scheduler
  limits_concurrency to: 1, key: ->(run) { run.account_backup_id }, duration: 15.minutes
  retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, wait: :polynomially_longer, attempts: 3
  discard_on ActiveJob::DeserializationError

  def perform(run)
    claimed = run.with_lock do
      next false unless run.pending?
      run.update!(status: :running, started_at: Time.current)
      true
    end
    return unless claimed

    account = run.account_backup
    raise AccountBackup::Reconciler::Stopped, "Discovery is paused" unless run.preview? || (account.active? && account.discovery_enabled?)
    names = discover_with_retries(run)
    run.complete!(AccountBackup::Reconciler.new(run).call(names))
  rescue AccountBackup::Reconciler::Stopped => e
    return unless run.running?
    run.update!(status: :skipped, error: e.message, finished_at: Time.current)
  rescue ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    run.update!(status: :pending) if run.persisted?
    raise
  rescue StandardError => e
    return unless AccountBackupDiscoveryRun.exists?(run.id)
    message = run.safe_error(e)
    run.update!(status: :failed, error: message, finished_at: Time.current)
    Rails.logger.warn "[Account discovery ##{run.id}] #{message}"
  end

  private
    def discover_with_retries(run)
      attempts = 0
      begin
        attempts += 1
        run.touch
        run.account_backup.source_provider.refresh_buckets
      rescue Rclone::Error
        retry if attempts < 3
        raise
      end
    end
end
