require "test_helper"

class Health::RuntimeStatusTest < ActiveSupport::TestCase
  setup do
    @settings = Health::Settings.new
    @check = Health::RuntimeStatus.new(settings: @settings, now: Time.current)
    process = Struct.new(:kind, :metadata, :last_heartbeat_at)
    @processes = [ process.new("Worker", { "queues" => "*" }, Time.current),
      process.new("Dispatcher", {}, Time.current),
      process.new("Scheduler", { "recurring_schedule" => Health::RuntimeStatus::REQUIRED_TASKS }, Time.current) ]
  end

  test "live workers and configured recurring tasks are healthy" do
    assert_equal "healthy", queue_status[:status]
  end

  test "wrong queue subscriptions and paused queues report errors" do
    @processes.first.metadata["queues"] = "default,backups"
    result = queue_status(paused: [ { queue_name: "backups" } ])
    assert_equal "error", result[:status]
    assert_includes result[:codes], "workers_missing"
    assert_includes result[:codes], "queues_paused"
    assert_includes result[:missing_queues], "health"
  end

  test "no live processes detects missing scheduler dispatcher and workers" do
    @processes = []
    result = queue_status
    assert_includes result[:codes], "workers_missing"
    assert_includes result[:codes], "scheduler_missing"
    assert_includes result[:codes], "dispatcher_missing"
  end

  test "queue database exceptions are sanitized" do
    SolidQueue::Process.stub :where, ->(*) { raise ActiveRecord::ConnectionNotEstablished, "secret connection string" } do
      result = @check.queue_status
      assert_equal [ "queue_unavailable" ], result[:codes]
      assert_not_includes result.to_json, "secret"
    end
  end

  test "heartbeats older than the configured timeout are filtered out" do
    @processes.first.last_heartbeat_at = 6.minutes.ago
    query = lambda do |conditions|
      @processes.select { |process| conditions.fetch(:last_heartbeat_at).cover?(process.last_heartbeat_at) }
    end
    SolidQueue::Process.stub :where, query do
      SolidQueue::Pause.stub :where, [] do
        assert_includes @check.queue_status[:codes], "workers_missing"
      end
    end
  end

  test "primary database exceptions produce a structured error report" do
    ApplicationRecord.stub :connection, -> { raise ActiveRecord::ConnectionNotEstablished, "secret connection string" } do
      result = Health::Report.new.call
      assert_equal "error", result[:status]
      assert_equal [ "database_unavailable" ], result.dig(:checks, :application, :codes)
      assert_not_includes result.to_json, "secret"
    end
  end

  private
    def queue_status(paused: [])
      SolidQueue::Process.stub :where, @processes do
        SolidQueue::Pause.stub(:where, paused) { @check.queue_status }
      end
    end
end
