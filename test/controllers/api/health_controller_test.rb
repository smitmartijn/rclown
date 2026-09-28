require "test_helper"

class Api::HealthControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_env = ENV.to_h.slice("HTTP_AUTH_USERNAME", "HTTP_AUTH_PASSWORD", "HEALTH_GRACE_PERIOD_SECONDS")
    ENV["HTTP_AUTH_USERNAME"] = "monitor"
    ENV["HTTP_AUTH_PASSWORD"] = "monitor-password"
    @auth = ActionController::HttpAuthentication::Basic.encode_credentials("monitor", "monitor-password")
    @runtime = Struct.new(:call).new({ status: "healthy", codes: [] })
    Backup.update_all(enabled: false)
  end

  teardown do
    %w[HTTP_AUTH_USERNAME HTTP_AUTH_PASSWORD HEALTH_GRACE_PERIOD_SECONDS].each { |key| ENV[key] = @original_env[key] }
  end

  test "requires the same basic authentication as the web interface" do
    get api_health_path
    assert_response :unauthorized
    get api_health_path, headers: { "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("monitor", "wrong") }
    assert_response :unauthorized
  end

  test "returns uncached structured JSON to non-browser clients without running probes" do
    Health::ConnectionProbe.stub :new, ->(*) { flunk "HTTP must not run remote probes" } do
      request_health
    end
    assert_response :ok
    assert_equal "application/json", response.media_type
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "healthy", response.parsed_body["status"]
    assert_equal 0, response.parsed_body.dig("summary", "monitored_backups")
    assert_equal 1, response.parsed_body["schema_version"]
    assert_not_includes response.body, "test_secret_key"
  end

  test "missed backups return warning and HTTP 503" do
    backup = backups(:weekly_backup)
    backup.runs.destroy_all
    backup.update_columns(enabled: true, created_at: 2.days.ago)
    request_health
    assert_response :service_unavailable
    assert_equal "warning", response.parsed_body["status"]
    assert_equal 1, response.parsed_body.dig("summary", "missed_backups")
  end

  test "queue failure is an application error even when no backups are due" do
    @runtime.call = { status: "error", codes: [ "workers_missing" ] }
    request_health
    assert_response :service_unavailable
    assert_equal "error", response.parsed_body["status"]
  end

  test "a running backup stays healthy while independent destination failures are reported" do
    backup = backups(:daily_backup)
    backup.update!(enabled: true)
    backup.runs.running.update_all(started_at: 3.days.ago)
    check = backup.create_health_check!(checked_at: Time.current,
      configuration_digest: BackupHealthCheck.configuration_digest(backup), results: {
        source: { status: "healthy", code: "cloud_list_accessible" },
        destination: { status: "healthy", code: "cloud_list_accessible" }
      })
    request_health
    assert_response :ok
    assert_equal "healthy", response.parsed_body["status"]
    assert_equal 1, response.parsed_body.dig("summary", "running_backups")

    check.update!(results: check.results.merge("destination" => { "status" => "error", "code" => "cloud_list_failed" }))
    request_health
    assert_response :service_unavailable
    assert_equal "healthy", response.parsed_body.dig("checks", "backups", "status")
    assert_equal "error", response.parsed_body.dig("checks", "connections", "status")
    provider = response.parsed_body["providers"].find { |row| row["id"] == backup.destination_storage.provider_id }
    assert_equal "error", provider["status"]
  end

  test "incomplete stored checks produce a warning instead of a broken JSON response" do
    backup = backups(:daily_backup)
    backup.update!(enabled: true)
    backup.create_health_check!(checked_at: Time.current,
      configuration_digest: BackupHealthCheck.configuration_digest(backup), results: { source: {} })
    request_health
    assert_response :service_unavailable
    assert_equal "warning", response.parsed_body["status"]
  end

  test "invalid configuration returns a sanitized JSON error" do
    ENV["HEALTH_GRACE_PERIOD_SECONDS"] = "secret-invalid-value"
    request_health
    assert_response :service_unavailable
    assert_equal "error", response.parsed_body["status"]
    assert_not_includes response.body, "secret-invalid-value"
  end

  private
    def request_health
      Health::RuntimeStatus.stub :new, ->(*) { @runtime } do
        get api_health_path, headers: { "Authorization" => @auth, "User-Agent" => "curl/8.0" }
      end
    end
end
