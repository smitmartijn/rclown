class CheckBackupHealthJob < ApplicationJob
  queue_as :health
  limits_concurrency to: 1, key: ->(check) { check.backup_id }, duration: 2.minutes
  discard_on ActiveJob::DeserializationError

  def perform(check)
    backup = check.backup
    return unless backup.health_monitored?
    digest = BackupHealthCheck.configuration_digest(backup)
    results = Health::ConnectionProbe.new(backup).call
    backup.reload
    return unless digest == BackupHealthCheck.configuration_digest(backup)
    check.update!(results: results, configuration_digest: digest, checked_at: Time.current, requested_at: nil)
  rescue ActiveRecord::RecordNotFound
    # The backup was removed during a probe.
  end
end
