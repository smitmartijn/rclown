require "digest"

class BackupHealthCheck < ApplicationRecord
  INTERVAL = 5.minutes
  RETRY_AFTER = 2.minutes

  belongs_to :backup

  def self.configuration_digest(backup)
    values = [ backup.source_path, backup.destination_path ]
    [ backup.source_storage, backup.destination_storage ].each do |storage|
      provider = storage.provider
      values.concat([ storage.id, storage.bucket_name, storage.usage_type, provider.id,
        provider.provider_type, provider.base_path, provider.endpoint, provider.region,
        provider.read_attribute_before_type_cast(:access_key_id), provider.read_attribute_before_type_cast(:secret_access_key) ])
    end
    Digest::SHA256.hexdigest(values.to_json)
  end

  def queue_if_due!
    queued = with_lock do
      touch
      next false if requested_at && requested_at > RETRY_AFTER.ago
      next false if checked_at && checked_at > INTERVAL.ago && configuration_digest == self.class.configuration_digest(backup)
      update!(requested_at: Time.current)
      true
    end
    CheckBackupHealthJob.perform_later(self) if queued
    queued
  end
end
