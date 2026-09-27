class Storage < ApplicationRecord
  belongs_to :provider

  has_many :account_backups, foreign_key: :destination_storage_id, dependent: :restrict_with_error

  has_many :source_backups, class_name: "Backup", foreign_key: :source_storage_id, dependent: :restrict_with_error
  has_many :destination_backups, class_name: "Backup", foreign_key: :destination_storage_id, dependent: :restrict_with_error

  enum :usage_type, { source_only: 0, destination_only: 1 }, prefix: true

  validates :bucket_name, presence: true
  validate :usage_type_compatible_with_existing_backups, if: :usage_type_changed?
  validate :local_root_storage
  validate :managed_source_identity_unchanged
  validate :provider_compatible_with_existing_backups, if: :provider_id_changed?

  scope :available_as_source, -> { where(usage_type: [ nil, :source_only ], provider_id: Provider.available_as_source.select(:id)) }
  scope :available_as_destination, -> { where(usage_type: [ nil, :destination_only ]) }

  def available_as_source?
    provider.supports_source? && (usage_type.nil? || usage_type_source_only?)
  end

  def available_as_destination?
    usage_type.nil? || usage_type_destination_only?
  end
  validates :bucket_name, uniqueness: { scope: :provider_id, message: "already exists for this provider" }

  def name
    display_name.presence || (provider.local? ? provider.name : bucket_name)
  end

  def rclone_path(remote_name = "remote", path: nil, retention: false)
    provider.rclone_target(bucket_name, path, remote_name: remote_name, retention: retention)
  end

  def root_name
    provider.storage_root_name(bucket_name)
  end

  def backups
    Backup.where(source_storage_id: id).or(Backup.where(destination_storage_id: id))
  end

  def in_use?
    backups.exists? || account_backups.exists?
  end

  private
    def managed_source_identity_unchanged
      if persisted? && (bucket_name_changed? || provider_id_changed?) && source_backups.joins(:account_backup_bucket).exists?
        errors.add(:base, "Cannot change source bucket identity while it is used by an account-managed backup; detach that backup first")
      end
    end

    def local_root_storage
      return unless provider&.local?

      errors.add(:bucket_name, "must be . for a local provider root") unless bucket_name == "."
      errors.add(:usage_type, "must be destination-only for local storage") unless usage_type_destination_only?
    end

    def provider_compatible_with_existing_backups
      if persisted? && (provider&.local? || Provider.find_by(id: provider_id_was)&.local?)
        errors.add(:provider, "cannot move an existing storage to or from a local provider; use its automatically created root storage")
      end
      if provider && !provider.supports_source? && source_backups.exists?
        errors.add(:provider, "cannot be destination-only while this storage is used as a source")
      end
    end

    def usage_type_compatible_with_existing_backups
      if usage_type_destination_only? && source_backups.exists?
        errors.add(:usage_type, "cannot be changed to destination-only while this storage is used as a source in existing backups. Please update or remove those backups first.")
      end

      if usage_type_source_only? && (destination_backups.exists? || account_backups.exists?)
        errors.add(:usage_type, "cannot be changed to source-only while this storage is used as a destination in existing backups. Please update or remove those backups first.")
      end
    end
end
