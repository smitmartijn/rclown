require "test_helper"

class CheckBackupHealthJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @backup = backups(:daily_backup)
    @check = @backup.create_health_check!
    @results = { "source" => { "status" => "healthy", "code" => "cloud_list_accessible" },
      "destination" => { "status" => "healthy", "code" => "cloud_list_accessible" } }
  end

  test "scheduling skips disabled backups and does not duplicate pending checks" do
    Backup.where.not(id: @backup.id).update_all(enabled: false)
    assert_enqueued_jobs 1, only: CheckBackupHealthJob do
      ScheduleBackupHealthChecksJob.perform_now
      ScheduleBackupHealthChecksJob.perform_now
    end
    assert @check.reload.requested_at
  end

  test "results are persisted and a recent check is not queued again" do
    Health::ConnectionProbe.stub :new, ->(*) { Struct.new(:call).new(@results) } do
      CheckBackupHealthJob.perform_now(@check)
    end
    assert_equal @results, @check.reload.results
    assert_equal BackupHealthCheck.configuration_digest(@backup), @check.configuration_digest
    assert @check.checked_at
    assert_no_enqueued_jobs(only: CheckBackupHealthJob) { @check.queue_if_due! }
  end

  test "a target change during the probe cannot publish a healthy result for the new target" do
    results = @results
    backup = @backup
    probe = Object.new
    probe.define_singleton_method(:call) do
      backup.update!(destination_path: "changed-during-check")
      results
    end
    Health::ConnectionProbe.stub(:new, ->(*) { probe }) { CheckBackupHealthJob.perform_now(@check) }
    assert_nil @check.reload.checked_at
  end

  test "expired requests are retried after worker interruption" do
    @check.update!(requested_at: 3.minutes.ago)
    assert_enqueued_jobs(1, only: CheckBackupHealthJob) { @check.queue_if_due! }
  end

  test "configuration fingerprints detect credentials and paths without invalidating on renames" do
    provider = @backup.source_storage.provider
    original = BackupHealthCheck.configuration_digest(@backup)
    provider.update!(name: "Renamed source")
    assert_equal original, BackupHealthCheck.configuration_digest(@backup)
    provider.update!(access_key_id: "replacement-access-key")
    assert_not_equal original, BackupHealthCheck.configuration_digest(@backup)
    digest = BackupHealthCheck.configuration_digest(@backup.reload)
    assert_equal digest, BackupHealthCheck.configuration_digest(@backup.reload)
  end
end
