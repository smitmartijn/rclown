class AccountBackupDiscoveryRun < ApplicationRecord
  belongs_to :account_backup
  enum :status, { pending: "pending", running: "running", success: "success", partial: "partial", failed: "failed", skipped: "skipped" }
  scope :in_progress, -> { where(status: [ :pending, :running ]) }
  scope :finished, -> { where.not(finished_at: nil) }

  after_update_commit :refresh_page
  after_update_commit :trim_history, if: :finished_at?

  def complete!(rows)
    update!(results: rows, counts: rows.map { |row| row.fetch("action") }.tally,
      status: rows.any? { |row| %w[conflict error].include?(row["action"]) } ? :partial : :success,
      finished_at: Time.current)
  end

  def safe_error(error)
    message = error.message.to_s.dup
    [ account_backup.source_provider, account_backup.destination_storage.provider ].each do |provider|
      [ provider.access_key_id, provider.secret_access_key ].compact_blank.each { |secret| message.gsub!(secret, "[FILTERED]") }
    end
    message.truncate(1000)
  end

  private
    def trim_history
      account_backup.discovery_runs.finished.order(id: :desc).offset(100).destroy_all
    end

    def refresh_page
      broadcast_refresh_to(account_backup) if finished_at?
    end
end
