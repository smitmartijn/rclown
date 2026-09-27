class AccountBackupBucket < ApplicationRecord
  belongs_to :account_backup
  belongs_to :backup, optional: true

  validates :bucket_name, presence: true, uniqueness: { scope: :account_backup_id }
  validates :backup_id, uniqueness: true, allow_nil: true

  def hold_reason
    if rule = account_backup.exclusion_for(bucket_name)
      "Bucket excluded by account rule: #{rule}"
    elsif !available?
      "Bucket is absent from the latest successful account discovery"
    end
  end

  def detach!
    account_backup.with_lock do
      account_backup.touch
      reload
      backup.update_columns(enabled: false) if backup && hold_reason
      account_backup.exclude_bucket!(bucket_name)
      update!(backup: nil, resolution: nil, last_error: nil)
    end
  end
end
