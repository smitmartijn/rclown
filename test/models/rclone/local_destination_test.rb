require "test_helper"
require_relative "../../support/local_destination"

class Rclone::LocalDestinationTest < ActiveSupport::TestCase
  include LocalDestination
  include ActiveJob::TestHelper

  setup { setup_local_destination }
  teardown { teardown_local_destination }

  test "local command uses separate arguments and no destination remote or cloud flags" do
    @local_backup.update!(destination_path: "cloud files/bucket;$(touch nope) 'quoted'")
    run = @local_backup.runs.create!(dry_run: true)
    config = Rclone::ConfigGenerator.new(@local_backup).generate
    command = Rclone::Executor.new(run).send(:build_command, config)
    assert_equal [ "rclone", "sync", "source:my-source-bucket", "#{@local_root}/#{@local_backup.destination_path}" ], command.first(4)
    assert_equal @local_backup.deleted_rclone_path, command[command.index("--backup-dir") + 1]
    assert_includes command, "--dry-run"
    assert_not_includes command, "--s3-upload-cutoff"
    assert_not_includes command, "--b2-upload-cutoff"
    contents = File.read(config.path)
    assert_includes contents, "[source]"
    assert_not_includes contents, "[destination]"
  ensure
    config&.close!
  end

  test "cloud commands keep their targets retention and upload flags" do
    %i[cloudflare backblaze amazon].each do |key|
      storage = providers(key).storages.create!(bucket_name: "command-test")
      backup = Backup.create!(source_storage: storages(:source_bucket), destination_storage: storage, destination_path: "prefix")
      run = backup.runs.create!
      config = Struct.new(:path).new("/tmp/config")
      command = Rclone::Executor.new(run).send(:build_command, config)
      flag = key == :backblaze ? "--b2-upload-cutoff" : "--s3-upload-cutoff"
      assert_equal [ "rclone", "sync", "source:my-source-bucket", "destination:command-test/prefix",
        "--backup-dir", "destination:command-test/.deleted/backups/#{backup.id}/#{Date.current.iso8601}/prefix",
        "--config", "/tmp/config", "--stats", "30s", "--stats-one-line", "--log-level", "NOTICE",
        "--disable", "ServerSideAcrossConfigs", flag, "0" ], command
    end
  end

  test "local retention is outside sync destination and isolated per backup" do
    assert_equal "#{@local_root}/.deleted/backups/#{@local_backup.id}/2026-09-27/cloudflare/my bucket",
      @local_backup.deleted_rclone_path(date: Date.new(2026, 9, 27))
    assert_equal "#{@local_root}/.deleted/backups/#{@local_backup.id}", @local_backup.deleted_rclone_base_path
    assert_not @local_backup.deleted_rclone_path.start_with?(@local_backup.destination_rclone_path + "/")
  end

  test "sync output and failed status reach history and notifications" do
    @local_backup.update!(verify_enabled: false)
    run = @local_backup.execute
    wait = Struct.new(:pid, :value).new(123, Struct.new(:exitstatus).new(5))
    process = lambda do |*command, &block|
      assert_equal @local_backup.destination_rclone_path, command[3]
      block.call(StringIO.new, StringIO.new("ERROR: permission denied accessing destination\n"), wait)
    end
    assert_enqueued_with(job: BackupFailureNotificationJob, args: [ run ]) do
      Open3.stub(:popen2e, process) { run.execute }
    end
    assert run.reload.failed?
    assert_equal 5, run.exit_code
    assert run.finished_at
    assert_match(/permission denied/, run.raw_log)
  end

  test "success still verifies sizes updates history and notifies" do
    run = @local_backup.execute
    wait = Struct.new(:pid, :value).new(123, Struct.new(:exitstatus).new(0))
    process = ->(*args, &block) { block.call(StringIO.new, StringIO.new("Transferred: 1\n"), wait) }
    size_paths = []
    sizes = lambda do |*command|
      size_paths << command[2]
      [ '{"count":1,"bytes":42}', "", Struct.new(:success?).new(true) ]
    end
    assert_enqueued_with(job: BackupSuccessNotificationJob, args: [ run ]) do
      Open3.stub :popen2e, process do
        Open3.stub(:capture3, sizes) { run.execute }
      end
    end
    assert run.reload.success?
    assert_equal @local_backup.destination_rclone_path, run.destination_rclone_path
    assert_equal 42, run.source_bytes
    assert_equal 1, run.source_count
    assert_equal [ @local_backup.source_rclone_path, @local_backup.destination_rclone_path ], size_paths
    assert @local_backup.reload.last_run_at
    assert_match(/VERIFY.*OK/, run.raw_log)
  end

  test "missing mount still schedules a failed run and notification" do
    FileUtils.remove_entry(@local_root)
    assert_enqueued_with(job: ExecuteBackupJob) { ScheduleBackupsJob.perform_now }
    run = @local_backup.runs.sole
    assert_enqueued_with(job: BackupFailureNotificationJob, args: [ run ]) { run.execute }
    assert run.reload.failed?
    assert_equal(-1, run.exit_code)
    assert_match(/Cannot access base directory/, run.raw_log)
  end

  test "symlink inserted after configuration prevents starting rclone" do
    File.symlink("/etc", "#{@local_root}/cloudflare")
    run = @local_backup.execute
    Open3.stub :popen2e, ->(*) { flunk "rclone must not run" } do
      run.execute
    end
    assert run.failed?
    assert_match(/Symlinks/, run.raw_log)
  end

  test "cleanup uses local paths and an empty configuration" do
    commands = []
    process = lambda do |*command|
      commands << command
      assert_equal "", File.read(command[command.index("--config") + 1])
      [ "", "", Struct.new(:success?).new(true) ]
    end
    Open3.stub :capture3, process do
      CleanupDeletedFilesJob.new.send(:cleanup_deleted_files, @local_backup)
    end
    assert_equal [ "rclone", "delete", @local_backup.deleted_rclone_base_path, "--min-age", "30d" ], commands.first.first(5)
    assert_equal [ "rclone", "rmdirs", @local_backup.deleted_rclone_base_path, "--leave-root" ], commands.last.first(4)
  end

  test "unsafe retention is skipped without stopping other cleanup" do
    File.symlink("/etc", "#{@local_root}/.deleted")
    commands = []
    process = ->(*command) { commands << command; [ "", "", Struct.new(:success?).new(true) ] }
    Open3.stub(:capture3, process) { CleanupDeletedFilesJob.perform_now }
    assert commands.any?
    assert commands.none? { |command| command[2].start_with?(@local_root) }
  end
end
