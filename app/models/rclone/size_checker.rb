require "open3"
require "timeout"

class Rclone::SizeChecker
  attr_reader :config_file, :rclone_path, :excludes

  TIMEOUT = 30.minutes

  def initialize(config_file, rclone_path:, excludes: [], backup_run: nil)
    @config_file = config_file
    @rclone_path = rclone_path
    @excludes = Array(excludes)
    @backup_run = backup_run
  end

  def check
    command = build_command
    stdout, stderr, status = nil

    if @backup_run
      stdout, stderr, status = Rclone::ProcessRunner.new(@backup_run).run(command, timeout: TIMEOUT.to_i)
    else
      Timeout.timeout(TIMEOUT.to_i) do
        stdout, stderr, status = Open3.capture3(*command)
      end
    end

    return nil unless status.success?

    parse_json(stdout)
  rescue Timeout::Error, JSON::ParserError => e
    Rails.logger.warn "[SizeChecker] Error checking size: #{e.message}"
    nil
  end

  private
    def build_command
      cmd = [
        "rclone", "size",
        rclone_path,
        "--json",
        "--config", config_file.path
      ]

      excludes.each do |pattern|
        cmd += [ "--exclude", pattern ]
      end

      cmd
    end

    def parse_json(output)
      data = JSON.parse(output)
      { count: data["count"], bytes: data["bytes"] }
    end
end
