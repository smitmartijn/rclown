require "test_helper"
require_relative "../support/account_discovery"

class AccountBackupsControllerTest < ActionDispatch::IntegrationTest
  include AccountDiscovery
  include ActiveJob::TestHelper

  setup { setup_account_discovery }
  teardown { teardown_local_destination }

  test "form and provider entry point offer account backups with destination-only local storage" do
    get new_account_backup_url
    assert_response :success
    assert_select "select[name='account_backup[source_provider_id]'] option[value='#{@local_provider.id}']", count: 0
    assert_select "select[name='account_backup[destination_storage_id]'] option[value='#{@local_storage.id}']"
    get provider_url(providers(:amazon))
    assert_select "a", text: "Back up this account"
    get account_backups_url
    assert_response :success
    get edit_account_backup_url(@account)
    assert_response :success
  end

  test "save creates draft queues preview and does not create backups" do
    attributes = { source_provider_id: providers(:amazon).id, destination_storage_id: @local_storage.id,
      destination_prefix: "aws", schedule: "weekly", retention_days: 60, excluded_pattern_names: "scratch-*" }
    assert_difference("AccountBackup.count", 1) do
      assert_no_difference [ "Backup.count", "Storage.count" ] do
        assert_enqueued_jobs 1, only: DiscoverAccountBackupBucketsJob do
          post account_backups_url, params: { account_backup: attributes }
        end
      end
    end
    account = AccountBackup.order(:id).last
    assert_redirected_to account_backup_url(account)
    assert_not account.active?
    assert account.discovery_runs.sole.preview?
    assert_equal "weekly", account.schedule
    follow_redirect!
    assert_response :success
    assert_select "h2", text: /Bucket preview/
  end

  test "invalid provider or unsafe prefix shows validation errors" do
    assert_no_difference "AccountBackup.count" do
      post account_backups_url, params: { account_backup: { source_provider_id: @local_provider.id, destination_storage_id: @local_storage.id, destination_prefix: "../etc" } }
    end
    assert_response :unprocessable_entity
    assert_select "li", text: /Source provider must support/
  end

  test "activating draft queues real discovery and pausing leaves backups alone" do
    @account.update!(activated_at: nil)
    assert_enqueued_jobs 1, only: DiscoverAccountBackupBucketsJob do
      post activate_account_backup_url(@account)
    end
    assert @account.reload.active?
    assert_not @account.discovery_runs.sole.preview?
    patch pause_account_backup_url(@account)
    assert_not @account.reload.discovery_enabled?
    assert @local_backup.reload.enabled?
  end

  test "editing defaults and exclusions preserves existing backups" do
    reconcile_buckets(%w[new-a new-b])
    backup = @account.buckets.find_by!(bucket_name: "new-a").backup
    original = backup.attributes
    patch account_backup_url(@account), params: { account_backup: { schedule: "weekly", retention_days: 90,
      excluded_buckets: [ "new-a" ], excluded_bucket_names: "future-bucket", excluded_pattern_names: "temp-*" } }
    assert_redirected_to account_backup_url(@account)
    assert_equal original, backup.reload.attributes
    assert_match(/excluded/, backup.account_hold_reason)
    assert_equal %w[future-bucket new-a], @account.reload.excluded_buckets
    get edit_account_backup_url(@account)
    assert_select "input[type=checkbox][value=new-a][checked]"
    assert_select "textarea[name='account_backup[excluded_bucket_names]']", text: "future-bucket"
    patch account_backup_url(@account), params: { account_backup: { excluded_buckets: [ "" ], excluded_bucket_names: "", excluded_pattern_names: "" } }
    assert_empty @account.reload.excluded_buckets
  end

  test "explicit link exclude detach and backup source protection" do
    reconcile_buckets([ "my-source-bucket" ])
    bucket = @account.buckets.sole
    patch account_backup_bucket_url(@account, bucket), params: { operation: "link", backup_id: @local_backup.id }
    assert_redirected_to account_backup_url(@account)
    assert_equal @local_backup.id, bucket.reload.backup_id
    patch backup_url(@local_backup), params: { backup: { source_path: "partial" } }
    assert_response :unprocessable_entity
    assert_nil @local_backup.reload.source_path
    patch account_backup_bucket_url(@account, bucket), params: { operation: "exclude" }
    assert_includes @account.reload.excluded_buckets, "my-source-bucket"
    get backup_url(@local_backup)
    assert_response :success
    assert_select "p", text: /Bucket excluded/
    patch account_backup_bucket_url(@account, bucket), params: { operation: "detach" }
    assert_nil bucket.reload.backup_id
    assert_not @local_backup.reload.enabled?
  end

  test "partial or wrong source backup cannot be linked" do
    reconcile_buckets([ "new-a" ])
    bucket = @account.buckets.sole
    patch account_backup_bucket_url(@account, bucket), params: { operation: "link", backup_id: @local_backup.id }
    assert_redirected_to account_backup_url(@account)
    assert_not_equal @local_backup.id, bucket.reload.backup_id
  end

  test "account deletion preserves child backups" do
    reconcile_buckets([ "new-a" ])
    assert_difference("AccountBackup.count", -1) do
      assert_no_difference("Backup.count") { delete account_backup_url(@account) }
    end
    assert_redirected_to account_backups_url
  end
end
