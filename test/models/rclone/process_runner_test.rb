require "test_helper"

class Rclone::ProcessRunnerTest < ActiveSupport::TestCase
  setup do
    @run = backup_runs(:running_run)
    @runner = Rclone::ProcessRunner.new(@run)
  end

  test "captures both streams without blocking on a full pipe" do
    stdout, stderr, status = @runner.run(ruby_command('STDOUT.write("x" * 100_000); STDERR.write("y" * 100_000)'), timeout: 5)
    assert_equal 100_000, stdout.bytesize
    assert_equal 100_000, stderr.bytesize
    assert status.success?
    assert_nil @run.reload.rclone_pid
  end

  test "stops a real silent child when cancellation is requested" do
    pid = nil
    assert_raises Rclone::ProcessRunner::Cancelled do
      @runner.run(ruby_command('STDOUT.sync = true; puts "ready"; sleep 60'), timeout: 10, capture: false) do |line|
        assert_equal "ready\n", line
        pid = @run.reload.rclone_pid
        assert @run.cancel
      end
    end
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    assert_nil @run.reload.rclone_pid
  end

  test "force stops a child that ignores TERM" do
    pid = nil
    assert_raises Rclone::ProcessRunner::Cancelled do
      @runner.run(ruby_command('trap("TERM", "IGNORE"); STDOUT.sync = true; puts "ready"; sleep 60'), timeout: 10) do
        pid = @run.reload.rclone_pid
        @run.cancel
      end
    end
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  test "timeout reaps the child and clears its pid" do
    pid = nil
    assert_raises Timeout::Error do
      @runner.run(ruby_command('STDOUT.sync = true; puts "ready"; sleep 60'), timeout: 0.5) do
        pid = @run.reload.rclone_pid
      end
    end
    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
    assert_nil @run.reload.rclone_pid
  end

  test "a stop requested before launch prevents spawning" do
    @run.cancel
    Open3.stub :popen3, ->(*) { flunk "must not launch a cancelled run" } do
      assert_raises(Rclone::ProcessRunner::Cancelled) { @runner.run(ruby_command("sleep 60"), timeout: 10) }
    end
  end

  private
    def ruby_command(source)
      [ RbConfig.ruby, "-e", source ]
    end
end
