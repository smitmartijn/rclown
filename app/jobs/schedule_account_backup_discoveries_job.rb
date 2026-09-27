class ScheduleAccountBackupDiscoveriesJob < ApplicationJob
  queue_as :scheduler

  def perform
    AccountBackup.due.find_each(&:queue_discovery!)
  end
end
