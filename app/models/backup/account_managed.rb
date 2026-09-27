module Backup::AccountManaged
  extend ActiveSupport::Concern

  included do
    has_one :account_backup_bucket, dependent: :nullify
    has_one :account_backup, through: :account_backup_bucket
    attr_accessor :account_backup_candidate

    before_destroy :exclude_destroyed_account_bucket, prepend: true
    validate :managed_source_unchanged
    validate :safe_managed_destination
  end

  def account_hold_reason
    account_backup_bucket&.hold_reason
  end

  def validate_account_destination!
    membership = account_backup_bucket
    return unless membership
    unless source_storage.provider_id == membership.account_backup.source_provider_id && source_storage.bucket_name == membership.bucket_name && source_path.blank?
      raise Rclone::Error, "Account-managed backup source has changed; detach it before changing its source"
    end
    conflict = destination_conflict
    raise Rclone::Error, "Destination overlaps backup '#{conflict.name}'" if conflict
  end

  private
    def managed_source_unchanged
      if account_backup_bucket && (source_storage_id_changed? || source_path_changed?)
        errors.add(:source_storage, "cannot change while account-managed; detach this backup first")
      end
    end

    def safe_managed_destination
      return unless destination_storage && source_storage
      return unless account_backup_candidate || account_backup_bucket || destination_storage_id_changed? || destination_path_changed?

      conflict = destination_conflict
      errors.add(:destination_path, "overlaps backup '#{conflict.name}'") if conflict
    rescue Rclone::Error => e
      errors.add(:destination_path, e.message)
    end

    def destination_conflict
      managed = account_backup_candidate || account_backup_bucket.present?
      others = Backup.where.not(id: id).includes(:account_backup_bucket, destination_storage: :provider)
      others = others.joins(:account_backup_bucket) unless managed
      return nil unless others.exists?

      target = destination_identity
      others.find do |other|
        begin
          identity = other.send(:destination_identity)
          target[0] == identity[0] && overlapping_paths?(target[1], identity[1])
        rescue Rclone::Error
          # Invalid existing local paths are not used as targets. A managed
          # candidate still goes through its own runtime path checks.
          false
        end
      end
    end

    def destination_identity
      provider = destination_storage.provider
      if provider.local?
        [ :local, destination_rclone_path ]
      else
        path = Pathname.new("/#{destination_path}").cleanpath.to_s.delete_prefix("/")
        [ [ provider.id, destination_storage.bucket_name ], path ]
      end
    end

    def overlapping_paths?(first, second)
      first == second || first.empty? || second.empty? || first.start_with?(second + "/") || second.start_with?(first + "/")
    end

    def exclude_destroyed_account_bucket
      membership = account_backup_bucket
      return unless membership

      membership.account_backup.with_lock do
        membership.account_backup.touch
        membership.account_backup.exclude_bucket!(membership.bucket_name)
      end
    end
end
