class AccountBackup < ApplicationRecord
  INTERVALS = { "Every 15 minutes" => 15, "Hourly" => 60, "Every 6 hours" => 360, "Daily" => 1440 }.freeze
  DEFAULT_ATTRIBUTES = %w[schedule comparison_mode retention_days verify_enabled verify_tolerance_percent].freeze

  belongs_to :source_provider, class_name: "Provider"
  belongs_to :destination_storage, class_name: "Storage"
  has_many :buckets, class_name: "AccountBackupBucket", dependent: :destroy
  has_many :discovery_runs, class_name: "AccountBackupDiscoveryRun", dependent: :destroy

  enum :schedule, Backup.schedules, prefix: true, validate: true
  enum :comparison_mode, Backup.comparison_modes, prefix: true, validate: true

  scope :active, -> { where.not(activated_at: nil) }
  scope :due, -> { active.where(discovery_enabled: true).where("next_discovery_at IS NULL OR next_discovery_at <= ?", Time.current) }

  before_validation :normalize_rules
  before_validation :generate_name
  before_destroy :preserve_held_backups, prepend: true
  validates :name, presence: true
  validates :source_provider_id, uniqueness: true
  validates :discovery_interval_minutes, inclusion: { in: INTERVALS.values }
  validates :retention_days, numericality: { only_integer: true, greater_than: 0 }
  validates :verify_tolerance_percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validate :eligible_storages
  validate :valid_prefix
  validate :immutable_source
  validate :valid_rules

  def active?
    activated_at.present?
  end

  def excluded_bucket_names
    excluded_buckets.join("\n")
  end

  def excluded_bucket_names=(value)
    self.excluded_buckets = value.to_s.lines.map(&:strip).reject(&:blank?).uniq
  end

  def excluded_pattern_names
    excluded_patterns.join("\n")
  end

  def excluded_pattern_names=(value)
    self.excluded_patterns = value.to_s.lines.map(&:strip).reject(&:blank?).uniq
  end

  def exclusion_for(name)
    return name if excluded_buckets.include?(name)

    excluded_patterns.find { |pattern| File.fnmatch?(pattern, name, File::FNM_DOTMATCH) }
  end

  def child_path(name)
    if name.blank? || [ ".", ".." ].include?(name) || name.match?(/[\/\\[:cntrl:]]/)
      raise Rclone::Error, "Bucket name is not a safe directory name"
    end
    [ destination_prefix.presence, name ].compact.join("/")
  end

  def backup_defaults
    DEFAULT_ATTRIBUTES.index_with { |key| public_send(key) }.merge("enabled" => backups_enabled)
  end

  # A direct write intentionally permits excluding/deleting a backup even when
  # its destination mount or old configuration is currently unavailable.
  def exclude_bucket!(name)
    update_columns(excluded_buckets: (excluded_buckets + [ name ]).uniq, updated_at: Time.current)
  end

  def activate!
    with_lock do
      touch
      update!(activated_at: activated_at || Time.current, discovery_enabled: true, next_discovery_at: Time.current)
    end
    queue_discovery!
  end

  def queue_discovery!(preview: false)
    run = with_lock do
      touch
      next unless preview || (active? && discovery_enabled?)

      discovery_runs.in_progress.where(updated_at: ...15.minutes.ago).update_all(
        status: "failed", error: "Discovery worker stopped responding; a new attempt may be queued.", finished_at: Time.current)
      next if discovery_runs.in_progress.exists?

      update_column(:next_discovery_at, discovery_interval_minutes.minutes.from_now) unless preview
      discovery_runs.create!(preview: preview)
    end
    DiscoverAccountBackupBucketsJob.perform_later(run) if run
    run
  rescue ActiveJob::EnqueueError => e
    run&.update!(status: :failed, error: "Unable to queue discovery", finished_at: Time.current)
    raise e
  end

  def attention_message
    latest = discovery_runs.where(preview: false).order(id: :desc).first
    return "Discovery is paused" if active? && !discovery_enabled?
    return "Not activated" unless active?
    return "Discovery has not completed yet" unless latest
    return latest.error.presence || "Discovery needs attention" if latest.failed? || latest.partial?
    return "Discovery is overdue; check the job worker" if latest.updated_at < (discovery_interval_minutes.minutes + 15.minutes).ago
    return "Some buckets are unavailable or need attention" if buckets.where(available: false).or(buckets.where.not(last_error: nil)).exists?

    nil
  end

  private
    def normalize_rules
      self.excluded_buckets = Array(excluded_buckets).map { |name| name.to_s.strip }.reject(&:blank?).uniq
      self.excluded_patterns = Array(excluded_patterns).map { |pattern| pattern.to_s.strip }.reject(&:blank?).uniq
    end

    def generate_name
      self.name = "#{source_provider.name} → #{destination_storage.name}" if name.blank? && source_provider && destination_storage
    end

    def eligible_storages
      if source_provider && !(source_provider.supports_source? && source_provider.supports_bucket_discovery?)
        errors.add(:source_provider, "must support cloud bucket discovery")
      end
      if destination_storage && !destination_storage.available_as_destination?
        errors.add(:destination_storage, "must allow destination usage")
      end
    end

    def immutable_source
      errors.add(:source_provider, "cannot be changed; create a new account backup") if persisted? && source_provider_id_changed?
    end

    def valid_prefix
      if destination_prefix.present? && (destination_prefix.start_with?("/") || destination_prefix.match?(/[\\[:cntrl:]]/) || destination_prefix.split("/", -1).any? { |part| [ "", ".", ".." ].include?(part) })
        errors.add(:destination_prefix, "must be a relative path without dot segments or empty components")
        return
      end
      if destination_storage && (new_record? || destination_storage_id_changed? || destination_prefix_changed?)
        destination_storage.provider.validate_destination!(child_path("bucket"))
      end
    rescue Rclone::Error => e
      errors.add(:destination_prefix, e.message)
    end

    def valid_rules
      (excluded_buckets + excluded_patterns).each do |rule|
        if rule.length > 255 || rule.match?(/[\/\\[:cntrl:]\[\]{}!]/)
          errors.add(:excluded_patterns, "use bucket names and only * or ? wildcards (maximum 255 characters)")
          break
        end
      end
    end

    def preserve_held_backups
      buckets.includes(:backup).each do |bucket|
        bucket.backup.update_columns(enabled: false) if bucket.backup && bucket.hold_reason
      end
    end
end
