require "test_helper"

class Health::AccountStatusTest < ActiveSupport::TestCase
  setup do
    @account = AccountBackup.create!(source_provider: providers(:cloudflare), destination_storage: storages(:destination_bucket), activated_at: Time.current)
    @settings = Health::Settings.new
  end

  test "initial discovery gets grace and pending jobs do not postpone overdue status" do
    assert_equal "healthy", report[:status]
    @account.update!(activated_at: 2.hours.ago)
    @account.discovery_runs.create!(status: :pending)
    assert_equal "discovery_overdue", report[:code]
  end

  test "running discovery stays healthy and paused or draft accounts are ignored" do
    @account.discovery_runs.create!(status: :failed, error: "sensitive error", finished_at: Time.current)
    assert_equal "discovery_failed", report[:code]
    @account.discovery_runs.create!(status: :running)
    assert_equal "discovery_running", report[:code]
    @account.update!(discovery_enabled: false)
    assert_equal "healthy", report[:status]
    assert_equal "discovery_paused", report[:code]
  end

  test "unavailable buckets need attention unless explicitly excluded" do
    @account.buckets.create!(bucket_name: "missing", available: false)
    assert_equal "warning", report[:status]
    @account.exclude_bucket!("missing")
    assert_equal "healthy", report[:status]
  end

  private
    def report
      Health::AccountStatus.new(@account, settings: @settings, now: Time.current).call
    end
end
