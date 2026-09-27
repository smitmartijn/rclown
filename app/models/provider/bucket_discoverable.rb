module Provider::BucketDiscoverable
  extend ActiveSupport::Concern

  CACHE_TTL = 10.minutes

  def discover_buckets
    raise Rclone::Error, "This provider does not support bucket discovery" unless supports_bucket_discovery?
    Rails.cache.fetch(bucket_cache_key, expires_in: CACHE_TTL) do
      Rclone::BucketLister.new(self).list
    end
  end

  def refresh_buckets
    Rails.cache.delete(bucket_cache_key)
    discover_buckets
  end

  def bucket_imported?(bucket_name)
    storages.exists?(bucket_name: bucket_name)
  end

  def import_bucket(bucket_name, display_name: nil)
    raise Rclone::Error, "This provider does not support bucket imports" unless supports_bucket_discovery?
    storages.create!(
      bucket_name: bucket_name,
      display_name: display_name
    )
  end

  private
    def bucket_cache_key
      "provider/#{id}/buckets"
    end
end
