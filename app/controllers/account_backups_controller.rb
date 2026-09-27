class AccountBackupsController < ApplicationController
  before_action :set_account_backup, only: %i[show edit update destroy preview activate discover pause]

  def index
    @account_backups = AccountBackup.includes(:source_provider, destination_storage: :provider).order(:name)
  end

  def show
    @runs = @account_backup.discovery_runs.order(id: :desc).limit(20)
    @buckets = @account_backup.buckets.includes(backup: [ :account_backup_bucket, :source_storage, :destination_storage ]).order(:bucket_name)
  end

  def new
    @account_backup = AccountBackup.new(source_provider_id: params[:provider_id])
  end

  def edit
  end

  def create
    @account_backup = AccountBackup.new(account_backup_params)
    if @account_backup.save
      @account_backup.queue_discovery!(preview: true)
      redirect_to @account_backup, notice: "Saved as a draft. Bucket preview is queued."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    saved = @account_backup.with_lock do
      @account_backup.touch
      @account_backup.update(account_backup_params)
    end
    if saved
      @account_backup.queue_discovery!(preview: true)
      redirect_to @account_backup, notice: "Settings saved. Defaults apply to new backups only; exclusion rules apply immediately."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def preview
    @account_backup.queue_discovery!(preview: true)
    redirect_to @account_backup, notice: "Preview queued, or discovery is already in progress."
  end

  def activate
    if @account_backup.discovery_runs.in_progress.exists?
      redirect_to @account_backup, alert: "Wait for the current discovery to finish before activating."
    else
      @account_backup.activate!
      redirect_to @account_backup, notice: "Account backup activated. Discovery is queued."
    end
  end

  def discover
    @account_backup.queue_discovery!
    redirect_to @account_backup, notice: "Discovery queued if active and not already in progress."
  end

  def pause
    @account_backup.with_lock do
      @account_backup.touch
      @account_backup.update!(discovery_enabled: !@account_backup.discovery_enabled?, next_discovery_at: Time.current)
    end
    redirect_to @account_backup, notice: "Discovery setting updated. Existing backup schedules are unchanged."
  end

  def destroy
    @account_backup.with_lock do
      @account_backup.touch
      @account_backup.destroy!
    end
    redirect_to account_backups_path, notice: "Account configuration removed. Backups and history were preserved; held backups remain disabled.", status: :see_other
  end

  private
    def set_account_backup
      @account_backup = AccountBackup.find(params[:id])
    end

    def account_backup_params
      attributes = params.require(:account_backup).permit(:name, :source_provider_id, :destination_storage_id,
        :destination_prefix, :discovery_enabled, :discovery_interval_minutes, :schedule, :comparison_mode,
        :retention_days, :verify_enabled, :verify_tolerance_percent, :backups_enabled,
        :excluded_bucket_names, :excluded_pattern_names, excluded_buckets: []).to_h
      if attributes.key?("excluded_bucket_names") || attributes.key?("excluded_buckets")
        names = attributes.delete("excluded_bucket_names").to_s.lines.map(&:strip)
        attributes["excluded_buckets"] = (names + Array(attributes["excluded_buckets"])).reject(&:blank?).uniq
      end
      attributes
    end
end
