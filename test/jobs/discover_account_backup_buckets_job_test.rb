require "test_helper"
require_relative "../support/account_discovery"

class DiscoverAccountBackupBucketsJobTest < ActiveSupport::TestCase
  include AccountDiscovery
  include ActiveJob::TestHelper

  setup { setup_account_discovery }
  teardown { teardown_local_destination }

  test "due scheduler queues once and skips paused and draft configurations" do
    assert_enqueued_jobs 1, only: DiscoverAccountBackupBucketsJob do
      ScheduleAccountBackupDiscoveriesJob.perform_now
      ScheduleAccountBackupDiscoveriesJob.perform_now
    end
    @account.discovery_runs.destroy_all
    @account.update!(discovery_enabled: false, next_discovery_at: nil)
    assert_no_enqueued_jobs(only: DiscoverAccountBackupBucketsJob) { ScheduleAccountBackupDiscoveriesJob.perform_now }
    @account.update!(discovery_enabled: true, activated_at: nil)
    assert_no_enqueued_jobs(only: DiscoverAccountBackupBucketsJob) { ScheduleAccountBackupDiscoveriesJob.perform_now }
  end

  test "job uses fresh discovery and creates backups" do
    run = @account.discovery_runs.create!
    lister = Struct.new(:list).new(%w[new-a new-b])
    Rclone::BucketLister.stub :new, lister do
      DiscoverAccountBackupBucketsJob.perform_now(run)
    end
    assert run.reload.success?, run.error
    assert_equal 2, @account.buckets.where.not(backup_id: nil).count
    assert_equal 2, run.counts["created"]
  end

  test "preview job creates only preview results" do
    run = @account.discovery_runs.create!(preview: true)
    Rclone::BucketLister.stub :new, Struct.new(:list).new([ "new-a" ]) do
      assert_no_difference [ "Storage.count", "Backup.count", "AccountBackupBucket.count" ] do
        DiscoverAccountBackupBucketsJob.perform_now(run)
      end
    end
    assert run.reload.success?, run.error
    assert_equal "create", run.results.first["action"]
  end

  test "failure preserves inventory and redacts credentials" do
    reconcile_buckets([ "new-a" ])
    run = @account.discovery_runs.create!
    lister = Object.new
    secret = @account.source_provider.secret_access_key
    lister.define_singleton_method(:list) { raise Rclone::Error, "Listing failed: #{secret}" }
    Rclone::BucketLister.stub(:new, lister) { DiscoverAccountBackupBucketsJob.perform_now(run) }
    assert run.reload.failed?
    assert @account.buckets.sole.available?
    assert_not_includes run.error, secret
    assert_includes run.error, "[FILTERED]"
  end

  test "pause during network listing prevents any reconciliation" do
    run = @account.discovery_runs.create!
    account_id = @account.id
    lister = Object.new
    lister.define_singleton_method(:list) do
      AccountBackup.find(account_id).update!(discovery_enabled: false)
      [ "new-a" ]
    end
    Rclone::BucketLister.stub :new, lister do
      assert_no_difference("Backup.count") { DiscoverAccountBackupBucketsJob.perform_now(run) }
    end
    assert run.reload.skipped?
  end

  test "duplicate job delivery does not rerun finished discovery" do
    run = @account.discovery_runs.create!(status: :success, finished_at: Time.current)
    Rclone::BucketLister.stub :new, ->(*) { flunk "should not list again" } do
      DiscoverAccountBackupBucketsJob.perform_now(run)
    end
    assert run.reload.success?
  end

  test "stale pending discovery can be recovered" do
    previous = @account.discovery_runs.create!(updated_at: 20.minutes.ago)
    run = @account.queue_discovery!
    assert run
    assert previous.reload.failed?
    assert run.pending?
  end
end
