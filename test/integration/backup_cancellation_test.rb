require "test_helper"

class BackupCancellationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "a separate connection can stop a worker even with its query cache enabled" do
    backup = Backup.create!(source_storage: storages(:source_bucket), destination_storage: storages(:destination_bucket), destination_path: "cancellation-test", verify_enabled: false)
    run = backup.runs.create!
    worker = nil
    original_constructor = Rclone::Executor.method(:new)
    constructor = lambda do |worker_run|
      original_constructor.call(worker_run).tap do |executor|
        executor.define_singleton_method(:build_command) do |_config|
          [ RbConfig.ruby, "-e", 'STDOUT.sync = true; puts "READY"; sleep 60' ]
        end
      end
    end

    Rclone::Executor.stub :new, constructor do
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.cache { BackupRun.find(run.id).execute }
        end
      end
      Timeout.timeout(10) do
        sleep 0.01 until run.raw_log&.lines&.include?("READY\n")
      end
      pid = run.reload.rclone_pid
      assert run.cancel
      assert worker.join(10), "The worker should observe the stop request from another connection"
      worker.value
      assert run.reload.cancelled?
      assert run.finished_at
      assert_nil run.rclone_pid
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    end
  ensure
    if worker&.alive?
      child_pid = run&.reload&.rclone_pid
      Process.kill("KILL", child_pid) if child_pid
      worker.join(5)
    end
    backup&.destroy!
  end
end
