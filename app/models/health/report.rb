class Health::Report
  SEVERITY = { "healthy" => 0, "warning" => 1, "error" => 2 }.freeze

  def self.worst(statuses)
    statuses.max_by { |status| SEVERITY.fetch(status) } || "healthy"
  end

  def initialize(now: Time.current, settings: Health::Settings.new)
    @now, @settings = now, settings
  end

  def call
    ApplicationRecord.connection.select_value("SELECT 1")
    runtime = Health::RuntimeStatus.new(settings: @settings, now: @now).call
    records = Backup.includes(:health_check, source_storage: :provider, destination_storage: :provider,
      account_backup_bucket: :account_backup).order(:id).to_a
    backups = records.map { |backup| Health::BackupStatus.new(backup, settings: @settings, now: @now).call }
    accounts = AccountBackup.order(:id).map { |account| Health::AccountStatus.new(account, settings: @settings, now: @now).call }
    providers = provider_statuses(records, backups)
    checks = { application: runtime,
      backups: { status: self.class.worst(backups.pluck(:status)) },
      connections: { status: self.class.worst(backups.map { |backup| backup[:connectivity][:status] }) },
      account_discovery: { status: self.class.worst(accounts.pluck(:status)) } }
    { schema_version: 1, status: self.class.worst(checks.values.pluck(:status)), checked_at: @now,
      settings: @settings.as_json, checks: checks, summary: { total_backups: backups.size,
        monitored_backups: backups.count { |backup| backup[:monitored] },
        running_backups: backups.count { |backup| %w[running stopping].include?(backup[:state]) },
        failed_backups: backups.count { |backup| backup[:state] == "failed" },
        missed_backups: backups.count { |backup| backup[:state] == "missed" } },
      backups: backups, providers: providers, account_backups: accounts }
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.error "Health database check failed: #{e.class}"
    { schema_version: 1, status: "error", checked_at: @now,
      checks: { application: { status: "error", codes: [ "database_unavailable" ] } } }
  end

  private
    def provider_statuses(records, backups)
      providers = {}
      records.zip(backups).each do |record, row|
        next unless row[:monitored]
        { "source" => record.source_storage, "destination" => record.destination_storage }.each do |role, storage|
          provider = storage.provider
          entry = providers[provider.id] ||= { id: provider.id, name: provider.name, type: provider.provider_type, targets: [] }
          connection = row[:connectivity]
          result = connection[:results][role]
          entry[:targets] << { backup_id: record.id, storage_id: storage.id, role: role,
            status: result ? result["status"] : connection[:status], code: result ? result["code"] : connection[:code],
            checked_at: connection[:checked_at], check_type: provider.local? ? "local_write" : "cloud_list" }
        end
      end
      providers.values.each { |entry| entry[:status] = self.class.worst(entry[:targets].pluck(:status)) }
    end
end
