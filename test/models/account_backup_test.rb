require "test_helper"
require_relative "../support/account_discovery"

class AccountBackupTest < ActiveSupport::TestCase
  include AccountDiscovery
  include ActiveJob::TestHelper

  setup { setup_account_discovery }
  teardown { teardown_local_destination }

  test "defaults source capability uniqueness and field validation" do
    assert_equal 60, @account.discovery_interval_minutes
    assert_equal "daily", @account.schedule
    assert_equal 30, @account.retention_days
    assert_equal "default", @account.comparison_mode
    assert @account.verify_enabled?
    duplicate = @account.dup
    assert_not duplicate.valid?
    assert duplicate.errors[:source_provider_id].present?
    @account.source_provider = @local_provider
    assert_not @account.valid?
    @account.source_provider = providers(:cloudflare)
    @account.retention_days = 0
    @account.verify_tolerance_percent = 101
    @account.discovery_interval_minutes = 1
    assert_not @account.valid?
    assert @account.errors[:retention_days].present?
    assert @account.errors[:verify_tolerance_percent].present?
    assert @account.errors[:discovery_interval_minutes].present?
  end

  test "prefix and bucket names cannot escape a local destination" do
    [ "../", "/etc", ".deleted", "a/../b", "a//b", "a/", "a\\b" ].each do |prefix|
      @account.destination_prefix = prefix
      assert_not @account.valid?, prefix
    end
    @account.destination_prefix = "cloudflare"
    assert @account.valid?
    assert_equal "cloudflare/example", @account.child_path("example")
    [ "", ".", "..", "../etc", "/etc", "a\\b", "a\0b" ].each do |name|
      assert_raises(Rclone::Error) { @account.child_path(name) }
    end
  end

  test "exact and glob exclusions match full case sensitive names" do
    @account.update!(excluded_bucket_names: "literal*name\nexact\n", excluded_pattern_names: "preview-*\n?-temporary")
    assert @account.exclusion_for("literal*name")
    assert_not @account.exclusion_for("literalXXname")
    assert @account.exclusion_for("exact")
    assert @account.exclusion_for("preview-")
    assert @account.exclusion_for("a-temporary")
    assert_not @account.exclusion_for("aa-temporary")
    assert_not @account.exclusion_for("Preview-one")
    assert_not @account.exclusion_for("xpreview-one")
    @account.excluded_pattern_names = "[a-z]*"
    assert_not @account.valid?
  end

  test "fresh preview writes no storages backups or memberships" do
    assert_no_difference [ "Storage.count", "Backup.count", "AccountBackupBucket.count", "BackupRun.count" ] do
      run = reconcile_buckets(%w[new-a new-b], preview: true)
      assert_equal [ "create", "create" ], run.results.pluck("action")
      assert_equal "#{@local_root}/new-a", run.results.first["destination"]
      assert run.success?
    end
  end

  test "creates one ordinary backup per included bucket and repeated discovery is idempotent" do
    @account.update!(destination_prefix: "cloudflare", excluded_patterns: [ "skip-*" ], comparison_mode: :checksum, schedule: :weekly, retention_days: 90)
    assert_difference "Backup.count", 3 do
      assert_difference "Storage.count", 3 do
        reconcile_buckets(%w[new-a new-b new-c skip-this])
      end
    end
    assert_equal 4, @account.buckets.count
    assert_nil @account.buckets.find_by!(bucket_name: "skip-this").backup
    backup = @account.buckets.find_by!(bucket_name: "new-a").backup
    assert_equal "cloudflare/new-a", backup.destination_path
    assert_equal "weekly", backup.schedule
    assert_equal "checksum", backup.comparison_mode
    assert_equal 90, backup.retention_days
    assert_no_difference [ "Backup.count", "Storage.count" ] do
      reconcile_buckets(%w[new-a new-b new-c skip-this])
    end
  end

  test "links matching existing backup without changing settings history or queueing it" do
    @local_backup.update!(destination_path: "my-source-bucket", enabled: false, schedule: :weekly, retention_days: 99)
    history = @local_backup.runs.create!(status: :success)
    @account.update!(backups_enabled: true)
    before = @local_backup.attributes.except("updated_at")
    assert_no_difference [ "Backup.count", "BackupRun.count" ] do
      run = reconcile_buckets([ "my-source-bucket" ])
      assert_equal "linked", run.results.first["action"]
    end
    assert_equal @local_backup.id, @account.buckets.sole.backup_id
    assert_equal before, @local_backup.reload.attributes.except("updated_at")
    assert @local_backup.runs.exists?(history.id)
  end

  test "individual edits survive changed defaults and new buckets get updated defaults" do
    reconcile_buckets([ "new-a" ])
    backup = @account.buckets.sole.backup
    backup.update!(destination_path: "custom/place", schedule: :weekly, comparison_mode: :size_only, enabled: false)
    @account.update!(destination_prefix: "changed", schedule: :daily, comparison_mode: :checksum, backups_enabled: true)
    assert_enqueued_jobs 1, only: ExecuteBackupJob do
      reconcile_buckets(%w[new-a new-b])
    end
    assert_equal "custom/place", backup.reload.destination_path
    assert_equal "size_only", backup.comparison_mode
    assert_equal "weekly", backup.schedule
    assert_not backup.enabled?
    fresh = @account.buckets.find_by!(bucket_name: "new-b").backup
    assert_equal "changed/new-b", fresh.destination_path
    assert_equal "checksum", fresh.comparison_mode
    assert fresh.enabled?
    assert_equal 1, fresh.runs.pending.count
  end

  test "excluded buckets hold execution and cleanup without mutating enabled" do
    @account.update!(backups_enabled: true)
    reconcile_buckets([ "new-a" ])
    backup = @account.buckets.sole.backup
    queued = backup.runs.pending.sole
    @account.update!(excluded_buckets: [ "new-a" ])
    assert backup.reload.enabled?
    assert_nil backup.execute
    Open3.stub :popen2e, ->(*) { flunk "must not execute held backup" } do
      queued.execute
    end
    assert queued.reload.skipped?
    assert_match(/excluded/, queued.raw_log)
    Open3.stub :capture3, ->(*) { flunk "must not clean held backup" } do
      CleanupDeletedFilesJob.new.send(:cleanup_deleted_files, backup.reload)
    end
    backup.update!(enabled: false)
    @account.update!(excluded_buckets: [])
    assert_nil backup.reload.account_hold_reason
    assert_not backup.enabled?
  end

  test "missing and reappearing buckets preserve files records and manual disabling" do
    reconcile_buckets(%w[new-a new-b])
    backup = @account.buckets.find_by!(bucket_name: "new-a").backup
    FileUtils.mkdir_p(backup.destination_rclone_path)
    file = File.join(backup.destination_rclone_path, "keep")
    File.write(file, "data")
    run = reconcile_buckets([ "new-b" ])
    assert_equal 1, run.counts["missing"]
    assert_match(/absent/, backup.reload.account_hold_reason)
    assert_equal "data", File.read(file)
    reconcile_buckets(%w[new-a new-b])
    assert_nil backup.reload.account_hold_reason
    assert_not backup.enabled?
  end

  test "deleting a managed backup excludes it permanently" do
    reconcile_buckets([ "new-a" ])
    backup = @account.buckets.sole.backup
    backup.destroy!
    assert_includes @account.reload.excluded_buckets, "new-a"
    assert_no_difference "Backup.count" do
      reconcile_buckets([ "new-a" ])
    end
    assert_nil @account.buckets.sole.backup
  end

  test "detaching held backup disables it and prevents recreation" do
    reconcile_buckets([ "new-a" ])
    bucket = @account.buckets.sole
    backup = bucket.backup
    backup.update!(enabled: true)
    @account.update!(excluded_buckets: [ "new-a" ])
    bucket.reload.detach!
    assert_nil backup.reload.account_backup_bucket
    assert_not backup.enabled?
    assert_nil bucket.reload.backup_id
    assert_no_difference("Backup.count") { reconcile_buckets([ "new-a" ]) }
  end

  test "deleting account preserves backups history and held disabled state" do
    reconcile_buckets(%w[new-a new-b])
    backups = @account.buckets.map(&:backup)
    backups.each { |backup| backup.update!(enabled: true) }
    history = backups.first.runs.create!(status: :success)
    @account.update!(excluded_buckets: [ "new-a" ])
    assert_no_difference [ "Backup.count", "BackupRun.count" ] do
      @account.destroy!
    end
    assert_not backups.first.reload.enabled?
    assert backups.last.reload.enabled?
    assert_nil backups.first.account_backup_bucket
    assert BackupRun.exists?(history.id)
  end

  test "conflicting existing backup requires explicit linking or creation" do
    run = reconcile_buckets([ "my-source-bucket" ])
    bucket = @account.buckets.sole
    assert_equal "conflict", run.results.first["action"]
    assert_nil bucket.backup
    AccountBackup::Reconciler.new(run).link_existing!(bucket, @local_backup)
    assert_equal @local_backup.id, bucket.reload.backup_id
    assert_equal "cloudflare/my bucket", @local_backup.reload.destination_path
    assert_no_difference("Backup.count") { reconcile_buckets([ "my-source-bucket" ]) }
  end

  test "explicit create another uses a distinct destination and source-only conflicts remain blocked" do
    reconcile_buckets([ "my-source-bucket" ])
    bucket = @account.buckets.sole
    bucket.update!(resolution: "create")
    assert_difference("Backup.count", 1) { reconcile_buckets([ "my-source-bucket" ]) }
    assert_equal "my-source-bucket", bucket.reload.backup.destination_path
    restricted = @account.source_provider.storages.create!(bucket_name: "restricted", usage_type: :destination_only)
    run = reconcile_buckets([ restricted.bucket_name ])
    assert_equal "error", run.results.first["action"]
    assert_nil @account.buckets.find_by!(bucket_name: restricted.bucket_name).backup_id
  end

  test "managed source edits and overlapping destinations are rejected" do
    reconcile_buckets(%w[new-a new-b])
    backup = @account.buckets.find_by!(bucket_name: "new-a").backup
    backup.source_path = "subfolder"
    assert_not backup.valid?
    backup.source_path = nil
    backup.destination_path = "new-b/child"
    assert_not backup.valid?
    assert_match(/overlaps/, backup.errors[:destination_path].join)
    backup.destination_path = "new-b-different"
    assert backup.valid?
  end

  test "overlap checks compare local targets across provider records" do
    reconcile_buckets([ "new-a" ])
    second = Provider.create!(name: "Same mount", provider_type: :local, base_path: @local_root)
    candidate = Backup.new(source_storage: storages(:source_bucket), destination_storage: second.storages.sole, destination_path: "new-a/nested")
    assert_not candidate.valid?
    assert_match(/overlaps/, candidate.errors[:destination_path].join)
  end

  test "unsafe or conflicting bucket does not prevent another bucket being handled" do
    File.symlink("/etc", File.join(@local_root, "unsafe"))
    run = reconcile_buckets([ "../escape", "unsafe", ".deleted", "safe" ])
    assert_equal 3, run.counts["error"]
    assert_equal 1, run.counts["created"]
    assert run.partial?
    assert @account.buckets.find_by!(bucket_name: "safe").backup
    assert_not @account.source_provider.storages.exists?(bucket_name: "unsafe")
  end

  test "cloud target mapping and self-target detection" do
    cloud_destination = providers(:backblaze).storages.create!(bucket_name: "account-backups")
    @account.update!(destination_storage: cloud_destination, destination_prefix: "r2")
    reconcile_buckets([ "new-cloud" ])
    backup = @account.buckets.sole.backup
    assert_equal "destination:account-backups/r2/new-cloud", backup.destination_rclone_path
    @account.update!(destination_storage: storages(:source_bucket))
    run = reconcile_buckets([ "my-source-bucket" ])
    assert_includes %w[error conflict], run.results.first["action"]
  end

  test "source and destination dependencies prevent deleting configured storages" do
    assert_not @account.source_provider.destroy
    assert @account.source_provider.persisted?
    assert_not @local_storage.destroy
    assert @local_storage.persisted?
  end

  test "source storage identity cannot be changed behind a managed backup" do
    reconcile_buckets([ "new-a" ])
    backup = @account.buckets.sole.backup
    storage = backup.source_storage
    storage.bucket_name = "different-source"
    assert_not storage.valid?
    assert_match(/source bucket identity/, storage.errors[:base].join)
    storage.update_column(:bucket_name, "bypassed-validation")
    assert_raises(Rclone::Error) { backup.reload.validate_destination! }
  end

  test "source provider cannot become local before any buckets are imported" do
    provider = Provider.create!(name: "Empty source", provider_type: :amazon_s3, access_key_id: "key", secret_access_key: "secret")
    AccountBackup.create!(source_provider: provider, destination_storage: @local_storage)
    provider.assign_attributes(provider_type: :local, base_path: @local_root)
    assert_not provider.valid?
    assert provider.errors[:provider_type].present?
  end

  test "scheduled execution rechecks enabled state after scheduling" do
    @local_backup.update!(enabled: false)
    assert_nil @local_backup.execute(scheduled: true)
    assert @local_backup.execute
  end

  test "only one normal execution is queued while pending and dry runs remain independent" do
    backup = @local_backup
    assert_difference "BackupRun.count", 1 do
      assert backup.execute
      assert_nil backup.execute
    end
    assert backup.execute(dry_run: true)
  end
end
