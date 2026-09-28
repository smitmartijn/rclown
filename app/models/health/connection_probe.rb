require "securerandom"
require "tempfile"

class Health::ConnectionProbe
  TIMEOUT = 15

  def initialize(backup)
    @backup = backup
  end

  def call
    { "source" => check(@backup.source_storage, @backup.source_path, source: true),
      "destination" => check(@backup.destination_storage, @backup.destination_path, source: false) }
  end

  private
    def check(storage, path, source:)
      allowed = source ? storage.available_as_source? : storage.available_as_destination?
      return result("error", "usage_not_allowed") unless allowed

      if storage.provider.local?
        @backup.validate_destination!
        # A tiny temporary write catches read-only/full mounts; it is always removed.
        root = Provider::LocalPath.new(storage.provider.base_path).root!
        Tempfile.create([ ".rclown-health-", ".tmp" ], root) do |file|
          file.write("health\n")
          file.flush
          file.fsync
        end
        result("healthy", "local_writable")
      else
        check_cloud(storage, path)
      end
    rescue Timeout::Error
      result("error", "connection_timeout")
    rescue Errno::ENOENT
      result("error", "executable_or_path_missing")
    rescue StandardError => e
      # Never persist raw provider responses, paths, credentials, or config contents.
      Rails.logger.warn "Health probe failed for storage #{storage.id}: #{e.class}"
      result("error", "connection_check_failed")
    end

    def check_cloud(storage, path)
      Tempfile.create([ "rclown-health", ".conf" ]) do |config|
        config.write(storage.provider.rclone_config_section("remote"))
        config.flush
        # Probe a random, nonexistent sub-prefix: bucket-scoped credentials work,
        # and a health check does not enumerate a potentially enormous backup.
        probe_path = [ path.presence, ".rclown-health-#{SecureRandom.hex(16)}" ].compact.join("/")
        target = storage.rclone_path("remote", path: probe_path)
        command = [ "rclone", "lsf", target, "--max-depth", "1", "--format", "p",
          "--config", config.path, "--contimeout", "5s", "--timeout", "10s",
          "--retries", "1", "--low-level-retries", "1", "--log-level", "ERROR" ]
        _, _, status = Rclone::ProcessRunner.new.run(command, timeout: TIMEOUT, capture: false)
        result(status.success? ? "healthy" : "error", status.success? ? "cloud_list_accessible" : "cloud_list_failed")
      end
    end

    def result(status, code)
      { "status" => status, "code" => code }
    end
end
