require "test_helper"
require_relative "../../support/local_destination"

class Health::ConnectionProbeTest < ActiveSupport::TestCase
  include LocalDestination

  setup { setup_local_destination }
  teardown { teardown_local_destination }

  test "cloud probe uses configured prefix read-only commands and removes its credential file" do
    @local_backup.update!(source_path: "scoped/source")
    config_paths = []
    commands = []
    callback = lambda do |command, **options|
      commands << command
      config_path = command[command.index("--config") + 1]
      config_paths << config_path
      assert File.exist?(config_path)
      assert_equal 15, options[:timeout]
      [ "", "", Struct.new(:success?).new(true) ]
    end
    result = with_runner(callback) { Health::ConnectionProbe.new(@local_backup).call }
    assert_equal "healthy", result.dig("source", "status")
    assert_equal "local_writable", result.dig("destination", "code")
    assert_equal %w[rclone lsf], commands.first.first(2)
    assert_match(%r{\Aremote:my-source-bucket/scoped/source/\.rclown-health-[0-9a-f]{32}\z}, commands.first[2])
    assert config_paths.none? { |path| File.exist?(path) }
    assert Dir.children(@local_root).none? { |name| name.start_with?(".rclown-health-") }
  end

  test "missing local mount and cloud failures are errors without leaking output" do
    FileUtils.remove_entry(@local_root)
    callback = ->(*) { [ "", "test_secret_key_cf signed-url", Struct.new(:success?).new(false) ] }
    result = with_runner(callback) { Health::ConnectionProbe.new(@local_backup).call }
    assert_equal "error", result.dig("source", "status")
    assert_equal "error", result.dig("destination", "status")
    assert_not_includes result.to_json, "test_secret"
    assert_not_includes result.to_json, "signed-url"
  end

  test "timeouts are bounded and do not prevent checking the destination" do
    callback = ->(*) { raise Timeout::Error }
    result = with_runner(callback) { Health::ConnectionProbe.new(@local_backup).call }
    assert_equal "connection_timeout", result.dig("source", "code")
    assert_equal "healthy", result.dig("destination", "status")
  end

  test "invalid local target is reported without writing outside the base directory" do
    File.symlink("/etc", File.join(@local_root, "cloudflare"))
    callback = ->(*) { [ "", "", Struct.new(:success?).new(true) ] }
    result = with_runner(callback) { Health::ConnectionProbe.new(@local_backup).call }
    assert_equal "error", result.dig("destination", "status")
  end

  private
    def with_runner(callback)
      runner = Object.new
      runner.define_singleton_method(:run) { |*args, **options| callback.call(*args, **options) }
      Rclone::ProcessRunner.stub(:new, runner) { yield }
    end
end
