require "test_helper"
require_relative "../../support/local_destination"

class Provider::LocalPathTest < ActiveSupport::TestCase
  include LocalDestination

  setup { setup_local_destination }
  teardown { teardown_local_destination }

  test "creates a local provider without credentials and with destination storage" do
    assert_nil @local_provider.access_key_id
    assert_nil @local_provider.secret_access_key
    assert_nil @local_provider.endpoint
    assert_equal "Local Filesystem", @local_provider.provider_type_name
    assert_equal "", @local_provider.rclone_config_section
    assert @local_storage.available_as_destination?
    assert_not @local_storage.available_as_source?
    assert_includes Storage.available_as_destination, @local_storage
    assert_not_includes Storage.available_as_source, @local_storage
  end

  test "cloud providers still require credentials" do
    %i[cloudflare backblaze amazon].each do |key|
      provider = providers(key)
      provider.access_key_id = provider.secret_access_key = nil
      assert_not provider.valid?
      assert provider.errors[:access_key_id].present?
      assert provider.errors[:secret_access_key].present?
    end
  end

  test "requires an existing absolute writable directory other than root" do
    file = File.join(@local_root, "file")
    File.write(file, "test")
    [ nil, "", "/", "relative", "#{@local_root}/missing", file, "#{@local_root}\n" ].each do |path|
      @local_provider.base_path = path
      assert_not @local_provider.valid?, path.inspect
      assert @local_provider.errors[:base_path].present?
    end
  end

  test "reports permission denied on the root" do
    File.stub :writable?, false do
      assert_not @local_provider.valid?
      assert_match(/permission denied/, @local_provider.errors[:base_path].join)
    end
  end

  test "reports OS access errors" do
    File.stub :realpath, ->(*) { raise Errno::EACCES } do
      assert_not @local_provider.valid?
      assert_match(/Permission denied/, @local_provider.errors[:base_path].join)
    end
  end

  test "allows missing subdirectories and preserves spaces and shell characters" do
    path = "cloud files/bucket;$(touch nope) 'quoted'"
    @local_backup.destination_path = path
    assert @local_backup.valid?
    assert_equal "#{@local_root}/#{path}", @local_backup.destination_rclone_path
    assert_not File.exist?("#{@local_root}/cloud files")
  end

  test "tildes are literal child directory names" do
    @local_backup.destination_path = "~not-a-system-user/files"
    assert @local_backup.valid?
    assert_equal "#{@local_root}/~not-a-system-user/files", @local_backup.destination_rclone_path
  end

  test "rejects traversal absolute empty and reserved destination paths" do
    [ "", nil, ".", "..", "../", "../../etc", "/etc", "/", "foo/../../../etc", "foo/../bar",
      "foo/./bar", "foo//bar", "foo/", "foo\\..\\bar", "foo\0bar", ".deleted", ".deleted/backups", ".DELETED/data" ].each do |path|
      @local_backup.destination_path = path
      assert_not @local_backup.valid?, path.inspect
      assert @local_backup.errors[:destination_path].present?, path.inspect
      assert_raises(Provider::LocalPath::Error) { @local_backup.destination_rclone_path }
    end
  end

  test "rejects files in a directory path" do
    File.write(File.join(@local_root, "file"), "test")
    @local_backup.destination_path = "file/child"
    assert_not @local_backup.valid?
    assert_match(/not a directory/, @local_backup.errors[:destination_path].join)
  end

  test "rejects symlink parents including dangling and internal links" do
    Dir.mkdir(File.join(@local_root, "inside"))
    [ "/etc", "#{@local_root}/missing", "#{@local_root}/inside" ].each_with_index do |target, index|
      File.symlink(target, File.join(@local_root, "link#{index}"))
      @local_backup.destination_path = "link#{index}/child"
      assert_not @local_backup.valid?
      assert_match(/Symlinks/, @local_backup.errors[:destination_path].join)
    end
  end

  test "rejects symlink base directories" do
    link = "#{@local_root}/root-link"
    File.symlink(@local_root, link)
    @local_provider.base_path = link
    assert_not @local_provider.valid?
    assert_match(/symlinks/, @local_provider.errors[:base_path].join)
  end

  test "execution preflight rejects symlinks nested in destination or retention" do
    destination = @local_backup.destination_rclone_path
    retention = @local_backup.deleted_rclone_base_path
    [ destination, retention ].each do |path|
      FileUtils.mkdir_p(path)
      link = File.join(path, "escape")
      File.symlink("/etc", link)
      assert_raises(Provider::LocalPath::Error) { @local_backup.validate_destination!(inspect_tree: true) }
      File.unlink(link)
    end
  end

  test "execution preflight rejects hardlinks" do
    destination = @local_backup.destination_rclone_path
    FileUtils.mkdir_p(destination)
    original = File.join(@local_root, "original")
    File.write(original, "untouched")
    File.link(original, File.join(destination, "hardlink"))
    assert_raises(Provider::LocalPath::Error) { @local_backup.validate_destination!(inspect_tree: true) }
    assert_equal "untouched", File.read(original)
  end

  test "runtime rejects a root replaced by a symlink" do
    original = @local_provider.base_path
    moved = "#{original}-moved"
    File.rename(original, moved)
    File.symlink(moved, original)
    assert_raises(Provider::LocalPath::Error) { @local_backup.validate_destination!(inspect_tree: true) }
  ensure
    File.unlink(original) if original && File.symlink?(original)
    File.rename(moved, original) if moved && File.exist?(moved)
  end

  test "cannot move local root storage to a cloud provider" do
    @local_storage.provider = providers(:amazon)
    assert_not @local_storage.valid?
    assert @local_storage.errors[:provider].present?
  end

  test "local sources remain forbidden even if usage type is bypassed" do
    @local_storage.update_column(:usage_type, nil)
    assert_not_includes Storage.available_as_source, @local_storage
    @local_backup.source_storage = @local_storage
    @local_backup.destination_storage = storages(:destination_bucket)
    assert_not @local_backup.valid?
    assert @local_backup.errors[:source_storage].present?
  end

  test "cannot switch existing cloud provider to local" do
    provider = providers(:cloudflare)
    provider.assign_attributes(provider_type: :local, base_path: @local_root)
    assert_not provider.valid?
    assert provider.errors[:provider_type].present?
  end

  test "local storage cannot replace a source or use a forged bucket path" do
    storage = storages(:source_bucket)
    storage.assign_attributes(provider: @local_provider, bucket_name: "../../etc", usage_type: :destination_only)
    assert_not storage.valid?
    assert storage.errors[:provider].present?
    assert storage.errors[:bucket_name].present?
  end
end
