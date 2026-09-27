require "tmpdir"
require "fileutils"
require "minitest/mock"

module LocalDestination
  def setup_local_destination
    @local_root = File.realpath(Dir.mktmpdir("rclown local "))
    @local_provider = Provider.create!(name: "Local NAS", provider_type: :local, base_path: @local_root)
    @local_storage = @local_provider.storages.sole
    @local_backup = Backup.create!(source_storage: storages(:source_bucket), destination_storage: @local_storage,
      destination_path: "cloudflare/my bucket", schedule: :daily)
  end

  def teardown_local_destination
    @local_backup&.runs&.each(&:clear_log)
    FileUtils.remove_entry(@local_root) if @local_root && File.exist?(@local_root)
  end
end
