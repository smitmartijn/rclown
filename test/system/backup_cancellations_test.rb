require "application_system_test_case"

class BackupCancellationsTest < ApplicationSystemTestCase
  test "stop a run from its details and show progress until the worker acknowledges" do
    run = backup_runs(:running_run)
    run.clear_log
    visit backup_run_path(run.backup, run)
    click_button "Stop backup"
    assert_text "Waiting for the backup process to exit. This stops only the current run."
    assert_button "Stopping…", disabled: true
    assert run.reload.stopping?

    # The worker finishes only after the subprocess has exited.
    run.send(:record_result, success: false, exit_code: nil)
    page.refresh
    assert_text "Cancelled"
    assert_no_button "Stop backup"
    assert_no_button "Stopping…"
    assert_text "Backup stopped by user."
  end
end
