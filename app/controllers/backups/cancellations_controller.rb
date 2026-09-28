module Backups
  class CancellationsController < ApplicationController
    include BackupScoped

    def create
      @backup.cancel
      redirect_to @backup, notice: "Stop requested for running backups.", status: :see_other
    end
  end
end
