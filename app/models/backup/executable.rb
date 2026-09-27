module Backup::Executable
  extend ActiveSupport::Concern

  def execute(dry_run: false, scheduled: false)
    run = with_lock do
      touch
      next if scheduled && !due?
      next if account_hold_reason
      next if !dry_run && (runs.running.exists? || runs.pending.where(dry_run: false).exists?)

      runs.create!(dry_run: dry_run, **run_paths)
    end
    run&.execute_later
    run
  end

  def running?
    runs.running.exists?
  end

  def last_run
    runs.completed.order(finished_at: :desc).first
  end

  def last_successful_run
    runs.successful.order(finished_at: :desc).first
  end

  private
    def run_paths
      { source_rclone_path: source_rclone_path, destination_rclone_path: destination_rclone_path }
    rescue Provider::LocalPath::Error
      # Still enqueue a run so an unavailable mount is recorded in history and
      # triggers the normal failure notification when the worker checks again.
      {}
    end
end
