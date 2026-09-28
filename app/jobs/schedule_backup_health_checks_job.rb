class ScheduleBackupHealthChecksJob < ApplicationJob
  queue_as :scheduler

  def perform
    Backup.enabled.includes(:health_check, account_backup_bucket: :account_backup).find_each do |backup|
      next unless backup.health_monitored?
      check = BackupHealthCheck.find_or_create_by!(backup: backup)
      check.queue_if_due!
    end
  end
end
