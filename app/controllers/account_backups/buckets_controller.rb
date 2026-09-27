module AccountBackups
  class BucketsController < ApplicationController
    before_action :set_bucket

    def update
      case params[:operation]
      when "exclude"
        @account.with_lock do
          @account.touch
          @account.exclude_bucket!(@bucket.bucket_name)
        end
      when "detach"
        @bucket.detach!
      when "link"
        backup = Backup.find(params[:backup_id])
        AccountBackup::Reconciler.new(@account.discovery_runs.build).link_existing!(@bucket, backup)
      when "create"
        @account.with_lock do
          @account.touch
          @bucket.update!(resolution: "create", last_error: nil)
        end
        @account.queue_discovery!
      else
        return head :unprocessable_entity
      end
      redirect_to @account, notice: "Bucket setting updated."
    rescue ActiveRecord::RecordInvalid, Rclone::Error => e
      redirect_to @account, alert: e.message
    end

    private
      def set_bucket
        @account = AccountBackup.find(params[:account_backup_id])
        @bucket = @account.buckets.find(params[:id])
      end
  end
end
