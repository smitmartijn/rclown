require "test_helper"
require_relative "../support/local_destination"

class LocalRcloneTest < ActiveSupport::TestCase
  include LocalDestination

  setup do
    skip "Install rclone to run the filesystem integration test" unless ENV.fetch("PATH").split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, "rclone")) }
    setup_local_destination
  end
  teardown { teardown_local_destination }

  test "real rclone bucket discovery uses a structured listing" do
    provider = providers(:cloudflare)
    source_root = File.join(@local_root, "test buckets")
    FileUtils.mkdir_p(File.join(source_root, "first"))
    FileUtils.mkdir_p(File.join(source_root, "second"))
    config = "[remote]\ntype = alias\nremote = #{source_root}\n"
    provider.stub :rclone_config_section, config do
      assert_equal [ "first", "second" ], Rclone::BucketLister.new(provider).list
    end
  end

  test "real rclone sync verifies archives overwritten and deleted files and cleans up" do
    # Substitute an alias remote for cloud access; exercise the actual executor,
    # local backend, verification and cleanup without external credentials.
    source_root = File.join(@local_root, "test source")
    source = File.join(source_root, "my-source-bucket")
    FileUtils.mkdir_p(source)
    File.write(File.join(source, "changed.txt"), "original")
    File.write(File.join(source, "deleted.txt"), "deleted later")
    File.write(File.join(source, "space ; 'quoted'.txt"), "special characters")
    config = "[source]\ntype = alias\nremote = #{source_root}\n"
    destination = @local_backup.destination_rclone_path

    generator = Object.new
    generator.define_singleton_method(:generate) do
      Tempfile.new([ "rclone-test", ".conf" ]).tap { |file| file.write(config); file.flush }
    end
    Rclone::ConfigGenerator.stub :new, generator do
      dry_run = @local_backup.execute(dry_run: true)
      dry_run.execute
      assert dry_run.success?, dry_run.raw_log
      assert_not File.exist?(File.join(destination, "changed.txt"))

      first = @local_backup.execute
      first.execute
      assert first.success?, first.raw_log
      assert_equal "original", File.read(File.join(destination, "changed.txt"))
      assert_equal "special characters", File.read(File.join(destination, "space ; 'quoted'.txt"))

      File.write(File.join(source, "changed.txt"), "replacement with different size")
      File.unlink(File.join(source, "deleted.txt"))
      second = @local_backup.execute
      second.execute
      assert second.success?, second.raw_log
      assert_equal 2, second.source_count
      assert_equal "replacement with different size", File.read(File.join(destination, "changed.txt"))
      assert_not File.exist?(File.join(destination, "deleted.txt"))
    end

    archive = @local_backup.deleted_rclone_path
    assert_equal "original", File.read(File.join(archive, "changed.txt"))
    assert_equal "deleted later", File.read(File.join(archive, "deleted.txt"))
    File.utime(60.days.ago.to_time, 60.days.ago.to_time, File.join(archive, "deleted.txt"))
    CleanupDeletedFilesJob.new.send(:cleanup_deleted_files, @local_backup)
    assert_not File.exist?(File.join(archive, "deleted.txt"))
    assert File.exist?(File.join(archive, "changed.txt"))
    assert File.exist?(File.join(destination, "changed.txt"))
  end
end
