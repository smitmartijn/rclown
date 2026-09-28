require "open3"

module BackupRun::ProcessManageable
  extend ActiveSupport::Concern

  def record_pid(pid)
    update_column(:rclone_pid, pid)
  end

  def cancel
    with_lock do
      touch
      return false unless running?
      unless cancel_requested_at?
        update!(cancel_requested_at: Time.current)
        append_log("\nStop requested by user. Waiting for the backup process to exit.\n")
      end
      true
    end
  end

  def stopping?
    running? && cancel_requested_at?
  end

  def status_label
    stopping? ? "Stopping…" : status.capitalize
  end

  def process_running?
    return false unless rclone_pid.present?

    begin
      Process.kill(0, rclone_pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end
  end

  def worker_running?
    return false unless worker_pid.present?

    begin
      Process.kill(0, worker_pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end
  end

  def process_stats
    return nil unless process_running?

    begin
      output, _status = Open3.capture2("ps", "-p", rclone_pid.to_s, "-o", "%cpu,%mem")
      lines = output.strip.split("\n")
      return nil if lines.length < 2

      values = lines[1].split
      {
        cpu: values[0]&.to_f,
        memory: values[1]&.to_f
      }
    rescue
      nil
    end
  end
end
