module Backups
  module Runs
    class CancellationsController < ApplicationController
      include BackupScoped

      def create
        run = @backup.runs.find(params[:run_id])
        message = run.cancel ? "Stop requested. The backup will stop shortly." : "This backup run is no longer running."
        redirect_to backup_run_path(@backup, run), notice: message, status: :see_other
      end
    end
  end
end
