require "application_system_test_case"
require_relative "../support/local_destination"

class AccountBackupsTest < ApplicationSystemTestCase
  include LocalDestination
  include ActiveJob::TestHelper

  setup { setup_local_destination }
  teardown { teardown_local_destination }

  test "preview activate edit and exclude a bucket through the browser" do
    Rclone::BucketLister.stub :new, Struct.new(:list).new(%w[account-new scratch-new]) do
      visit new_account_backup_path
      fill_in "Name", with: "Cloudflare to NAS"
      select "Cloudflare R2", from: "Source provider"
      select "Local NAS (Local NAS)", from: "Destination"
      fill_in "Bucket patterns", with: "scratch-*"
      uncheck "Enable newly created backups"
      perform_enqueued_jobs(only: DiscoverAccountBackupBucketsJob) do
        click_button "Save and preview"
        assert_selector "h2", text: "Bucket preview — Success"
      end
      assert_text "#{@local_root}/account-new"
      assert_text "Matched rule: scratch-*"
      assert_equal 0, AccountBackupBucket.count
      perform_enqueued_jobs(only: DiscoverAccountBackupBucketsJob) do
        click_button "Activate account backup"
        assert_selector "h2", text: "Latest discovery — Success"
      end
      assert_selector "h2", text: "Managed buckets"
      account = AccountBackup.find_by!(name: "Cloudflare to NAS")
      backup = account.buckets.find_by!(bucket_name: "account-new").backup
      assert_equal "account-new", backup.destination_path
      assert_not backup.enabled?

      visit edit_backup_path(backup)
      choose "Weekly", allow_label_click: true
      fill_in "Retention days", with: "75"
      click_button "Update Backup"
      assert_selector "h1", text: "account-new → Local NAS"
      assert_equal 75, backup.reload.retention_days

      visit edit_account_backup_path(account)
      check "account-new"
      perform_enqueued_jobs(only: DiscoverAccountBackupBucketsJob) do
        click_button "Save and preview"
        assert_text "All visible buckets are excluded"
      end
      assert_match(/excluded/, backup.reload.account_hold_reason)
      assert_equal "weekly", backup.schedule
      assert_equal 75, backup.retention_days
      assert_not backup.enabled?
    end
  end
end
