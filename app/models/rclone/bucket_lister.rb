require "open3"
require "timeout"

class Rclone::BucketLister
  TIMEOUT = 2.minutes
  attr_reader :provider

  def initialize(provider)
    @provider = provider
  end

  def list
    config_file = generate_temp_config
    parse_bucket_list(execute_rclone(config_file))
  ensure
    config_file&.close!
  end

  private
    def generate_temp_config
      Tempfile.new([ "rclone", ".conf" ]).tap do |file|
        file.write(provider.rclone_config_section("remote"))
        file.flush
      end
    end

    def execute_rclone(config_file)
      command = [ "rclone", "lsjson", "remote:", "--dirs-only", "--config", config_file.path ]
      Open3.popen3(*command, pgroup: true) do |stdin, stdout, stderr, process|
        stdin.close
        readers = [ Thread.new { stdout.read }, Thread.new { stderr.read } ]
        begin
          status = Timeout.timeout(TIMEOUT.to_i) { process.value }
          output, error = readers.map(&:value)
          unless status.success?
            [ provider.access_key_id, provider.secret_access_key ].compact_blank.each { |secret| error.gsub!(secret, "[FILTERED]") }
            raise Rclone::Error, "Failed to list buckets: #{error.truncate(1000)}"
          end
          output
        rescue Timeout::Error
          terminate(process)
          raise Rclone::Error, "Bucket discovery timed out after #{TIMEOUT.to_i} seconds"
        ensure
          readers.each(&:join)
        end
      end
    end

    def terminate(process)
      Process.kill("TERM", -process.pid)
      unless process.join(2)
        Process.kill("KILL", -process.pid)
        process.join
      end
    rescue Errno::ESRCH
      # The subprocess exited while being terminated.
    end

    def parse_bucket_list(output)
      entries = JSON.parse(output)
      unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(Hash) && entry["IsDir"] == true && entry["Name"].is_a?(String) && entry["Name"].present? }
        raise Rclone::Error, "Bucket discovery returned an invalid directory listing"
      end
      entries.map { |entry| entry.fetch("Name") }.uniq.sort
    rescue JSON::ParserError
      raise Rclone::Error, "Bucket discovery returned invalid JSON"
    end
end
