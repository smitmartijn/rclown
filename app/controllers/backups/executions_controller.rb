module Backups
  class ExecutionsController < ApplicationController
    include BackupScoped

    def create
      if @backup.execute
        redirect_to @backup, notice: "Backup started."
      else
        redirect_to @backup, alert: @backup.account_hold_reason || "Backup is already pending or running."
      end
    end
  end
end
