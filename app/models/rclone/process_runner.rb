require "open3"
require "timeout"

# The worker owns and stops its child process. Web requests only set a database
# flag, so cancellation also works when the web and job processes are separate.
class Rclone::ProcessRunner
  class Cancelled < StandardError; end

  POLL_INTERVAL = 0.25
  STOP_GRACE_PERIOD = 5

  def initialize(backup_run)
    @backup_run = backup_run
  end

  def run(command, timeout:, capture: true)
    raise Cancelled if cancellation_requested?

    output = [ +"", +"" ]
    deadline = monotonic_time + timeout
    interruption = nil
    next_check = 0

    Open3.popen3(*command) do |stdin, stdout, stderr, process|
      begin
        stdin.close
        @backup_run.record_pid(process.pid)
        streams = { stdout => 0, stderr => 1 }
        buffers = { stdout => +"".b, stderr => +"".b }

        until streams.empty? && !process.alive?
          if !interruption && monotonic_time >= next_check
            next_check = monotonic_time + POLL_INTERVAL
            interruption = if cancellation_requested?
              Cancelled
            elsif monotonic_time >= deadline
              Timeout::Error
            end
            if interruption
              signal(process, "TERM")
              kill_at = monotonic_time + STOP_GRACE_PERIOD
            end
          end
          signal(process, "KILL") if interruption && monotonic_time >= kill_at

          ready = IO.select(streams.keys, nil, nil, POLL_INTERVAL)&.first || []
          ready.each do |stream|
            chunk = stream.read_nonblock(16_384, exception: false)
            next if chunk == :wait_readable
            if chunk.nil?
              yield buffers[stream] if block_given? && buffers[stream].present?
              streams.delete(stream)
            else
              output[streams[stream]] << chunk if capture
              if block_given?
                buffers[stream] << chunk.b
                while (newline = buffers[stream].index("\n"))
                  yield buffers[stream].slice!(0, newline + 1)
                end
              end
            end
          end
        end

        raise interruption if interruption
        raise Cancelled if cancellation_requested?
        [ *output, process.value ]
      ensure
        # Also reap the child if logging or a database operation raises.
        signal(process, "TERM")
        signal(process, "KILL") unless process.join(STOP_GRACE_PERIOD)
        process.join
        @backup_run.update_column(:rclone_pid, nil)
      end
    end
  end

  private
    def cancellation_requested?
      @backup_run.class.uncached do
        @backup_run.class.where(id: @backup_run.id).where.not(cancel_requested_at: nil).exists?
      end
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def signal(process, name)
      Process.kill(name, process.pid) if process.alive?
    rescue Errno::ESRCH
      # The child exited between the liveness check and the signal.
    end
end
