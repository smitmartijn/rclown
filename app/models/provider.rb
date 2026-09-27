class Provider < ApplicationRecord
  include RcloneConfigurable, BucketDiscoverable

  PROVIDER_TYPES = {
    cloudflare_r2: "Cloudflare R2",
    backblaze_b2: "Backblaze B2",
    amazon_s3: "Amazon S3",
    local: "Local Filesystem"
  }.freeze

  enum :provider_type, {
    cloudflare_r2: "cloudflare_r2",
    backblaze_b2: "backblaze_b2",
    amazon_s3: "amazon_s3",
    local: "local"
  }

  encrypts :access_key_id
  encrypts :secret_access_key

  has_many :storages, dependent: :destroy

  validates :name, presence: true
  validates :provider_type, presence: true
  validates :access_key_id, presence: true, unless: :local?
  validates :secret_access_key, presence: true, unless: :local?
  validates :endpoint, presence: true, if: :cloudflare_r2?
  validate :valid_local_root, if: :local?
  validate :storage_type_unchanged

  after_save :ensure_local_storage, if: :local?

  scope :available_as_source, -> { where.not(provider_type: :local) }

  def supports_source?
    !local?
  end

  def supports_bucket_discovery?
    !local?
  end

  def rclone_target(bucket, path = nil, remote_name: "remote", retention: false)
    if local?
      LocalPath.new(base_path).resolve!(path, retention: retention)
    else
      path.present? ? "#{remote_name}:#{bucket}/#{path}" : "#{remote_name}:#{bucket}"
    end
  end

  def validate_destination!(path, retention: false, inspect_tree: false)
    LocalPath.new(base_path).resolve!(path, retention: retention, inspect_tree: inspect_tree) if local?
  end

  def storage_root_name(bucket)
    local? ? base_path : bucket
  end

  def provider_type_name
    PROVIDER_TYPES[provider_type.to_sym]
  end

  private
    def valid_local_root
      self.base_path = LocalPath.new(base_path).root!
    rescue LocalPath::Error => e
      errors.add(:base_path, e.message)
    end

    def storage_type_unchanged
      if provider_type_changed? && persisted? && storages.exists? && [ provider_type, provider_type_was ].include?("local")
        errors.add(:provider_type, "cannot switch between cloud and local while storages exist; create a new provider instead")
      end
    end

    def ensure_local_storage
      storages.find_or_create_by!(bucket_name: ".") do |storage|
        storage.usage_type = :destination_only
      end
    end
end
