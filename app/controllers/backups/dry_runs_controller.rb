module Backups
  class DryRunsController < ApplicationController
    include BackupScoped

    def create
      if @backup.execute(dry_run: true)
        redirect_to @backup, notice: "Dry run started."
      else
        redirect_to @backup, alert: @backup.account_hold_reason || "Backup cannot start."
      end
    end
  end
end
