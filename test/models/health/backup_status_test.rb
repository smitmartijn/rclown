require "test_helper"

class Health::BackupStatusTest < ActiveSupport::TestCase
  setup do
    @now = Time.utc(2026, 9, 28, 12)
    travel_to @now
    @backup = backups(:daily_backup)
    @backup.runs.destroy_all
    @backup.update_columns(created_at: 10.days.ago, last_run_at: nil)
    @settings = Health::Settings.new
  end

  teardown { travel_back }

  test "allows the recent duration plus grace after the daily due time" do
    success(start: 25.hours.ago, duration: 2.hours)
    assert_equal "healthy", report[:status]
    assert_equal 2.hours, report[:expected_duration_seconds]
    assert_equal 90.minutes.from_now, report[:overdue_at]
    travel 90.minutes + 1.second
    assert_equal "warning", report[:status]
    assert_equal "missed", report[:state]
  end

  test "weekly schedules use a week and select the longest of ten successful durations" do
    @backup.update!(schedule: :weekly)
    success(start: 20.days.ago, duration: 12.hours)
    10.times { |i| success(start: (7 + i).days.ago, duration: (i + 1).minutes) }
    assert_equal 10.minutes, report[:expected_duration_seconds]
    assert_equal "healthy", report[:status]
    travel 41.minutes
    assert_equal "warning", report[:status]
  end

  test "running and stopping backups never become overdue even after a prior failure" do
    @backup.runs.create!(status: :failed, created_at: 3.days.ago, finished_at: 3.days.ago)
    run = @backup.runs.create!(status: :running, created_at: 2.days.ago, started_at: 2.days.ago)
    assert_equal "healthy", report[:status]
    assert_equal "running", report[:state]
    run.update!(cancel_requested_at: Time.current)
    assert_equal "healthy", report[:status]
    assert_equal "stopping", report[:state]
  end

  test "a long successful backup gets time for another run after it completes" do
    success(start: 27.hours.ago, duration: 26.hours)
    assert_equal 1.hour.ago, report[:expected_next_run_at]
    assert_equal "healthy", report[:status]
  end

  test "pending attempts do not keep moving a missed deadline" do
    success(start: 3.days.ago, duration: 1.hour)
    @backup.runs.create!(status: :pending)
    assert_equal "missed", report[:state]
    assert_equal "warning", report[:status]
  end

  test "new backups get grace from creation rather than waiting a whole schedule" do
    @backup.update_column(:created_at, 29.minutes.ago)
    assert_equal "healthy", report[:status]
    travel 2.minutes
    assert_equal "missed", report[:state]
  end

  test "failed backups are errors until recovery and dry runs cannot hide the failure" do
    @backup.runs.create!(status: :failed, created_at: 1.hour.ago, finished_at: 1.hour.ago)
    @backup.runs.create!(status: :success, dry_run: true, finished_at: Time.current)
    @backup.runs.create!(status: :running, dry_run: true, started_at: Time.current)
    assert_equal "error", report[:status]
    success(start: 10.minutes.ago, duration: 5.minutes)
    assert_equal "healthy", report[:status]
  end

  test "a cancelled backup warns only once the successful backup deadline is missed" do
    success(start: 5.hours.ago, duration: 10.minutes)
    @backup.runs.create!(status: :cancelled, finished_at: Time.current)
    assert_equal "healthy", report[:status]
    travel 1.day
    assert_equal "missed", report[:state]
  end

  test "disabled and excluded backups are ignored but a missing source bucket warns" do
    @backup.update!(enabled: false)
    assert_equal "disabled", report[:state]
    assert_equal "healthy", report[:connectivity][:status]
    @backup.update!(enabled: true)
    account = AccountBackup.create!(source_provider: @backup.source_storage.provider, destination_storage: @backup.destination_storage)
    bucket = account.buckets.create!(bucket_name: @backup.source_storage.bucket_name, backup: @backup, available: false)
    @backup.reload
    assert_equal "source_bucket_missing", report[:code]
    account.exclude_bucket!(bucket.bucket_name)
    @backup.reload
    assert_equal "excluded", report[:state]
    assert_not report[:monitored]
  end

  test "connection checks expose errors and become stale or invalid when configuration changes" do
    check = @backup.create_health_check!(checked_at: Time.current,
      configuration_digest: BackupHealthCheck.configuration_digest(@backup), results: {
        source: { status: "healthy", code: "cloud_list_accessible" },
        destination: { status: "error", code: "cloud_list_failed" }
      })
    assert_equal "error", report[:connectivity][:status]
    check.update!(checked_at: 16.minutes.ago)
    assert_equal "check_stale", report[:connectivity][:code]
    check.update!(checked_at: Time.current)
    @backup.update!(destination_path: "changed")
    assert_equal "configuration_changed", report[:connectivity][:code]
  end

  private
    def success(start:, duration:)
      @backup.runs.create!(status: :success, created_at: start, started_at: start, finished_at: start + duration)
    end

    def report
      Health::BackupStatus.new(@backup, settings: @settings, now: Time.current).call
    end
end
