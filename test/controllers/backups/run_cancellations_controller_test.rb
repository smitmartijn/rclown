require "test_helper"

class Backups::RunCancellationsControllerTest < ActionDispatch::IntegrationTest
  test "requests stopping only the selected run and redirects back to it" do
    run = backup_runs(:running_run)
    other = run.backup.runs.create!(status: :running, dry_run: true)
    post backup_run_cancellation_path(run.backup, run)
    assert_redirected_to backup_run_path(run.backup, run)
    assert run.reload.stopping?
    assert_nil other.reload.cancel_requested_at
    assert_nil run.finished_at
    assert run.backup.reload.enabled?
    follow_redirect!
    assert_select "button[disabled]", text: "Stopping…"
  end

  test "does not cancel a run belonging to another backup" do
    run = backup_runs(:running_run)
    post backup_run_cancellation_path(backups(:weekly_backup), run)
    assert_response :not_found
    assert_nil run.reload.cancel_requested_at
  end

  test "completed runs have no stop button and remain unchanged on a stale request" do
    run = backup_runs(:successful_run)
    get backup_run_path(run.backup, run)
    assert_select "button", text: "Stop backup", count: 0
    post backup_run_cancellation_path(run.backup, run)
    assert_redirected_to backup_run_path(run.backup, run)
    assert run.reload.success?
    assert_nil run.cancel_requested_at
    assert_match(/no longer running/, flash[:notice])
  end

  test "duplicate requests preserve the original request timestamp" do
    run = backup_runs(:running_run)
    post backup_run_cancellation_path(run.backup, run)
    requested_at = run.reload.cancel_requested_at
    post backup_run_cancellation_path(run.backup, run)
    assert_equal requested_at, run.reload.cancel_requested_at
  end
end
