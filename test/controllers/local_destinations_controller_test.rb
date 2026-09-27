require "test_helper"
require_relative "../support/local_destination"

class LocalDestinationsControllerTest < ActionDispatch::IntegrationTest
  include LocalDestination

  setup { setup_local_destination }
  teardown { teardown_local_destination }

  test "creates provider through the form without cloud credentials" do
    assert_difference("Provider.count") do
      post providers_url, params: { provider: { name: "NAS", provider_type: "local", base_path: @local_root } }
    end
    provider = Provider.last
    assert_redirected_to provider_url(provider)
    assert_equal @local_root, provider.base_path
    assert_equal 1, provider.storages.count
    follow_redirect!
    assert_response :success
    assert_select "dt", text: "Base path"
    assert_select "dt", text: "Access Key ID", count: 0
    assert_select "turbo-frame[src]", count: 0
  end

  test "provider form presents local path and hides cloud fields for local records" do
    get edit_provider_url(@local_provider)
    assert_response :success
    assert_select "input[value=local][checked]"
    assert_select "[data-provider-type-target=local]:not([hidden]) input[name='provider[base_path]']"
    assert_select "[data-provider-type-target=cloud][hidden]", count: 4
  end

  test "backup form offers local destinations but never local sources" do
    get new_backup_url
    assert_response :success
    assert_select "select[name='backup[destination_storage_id]'] option[value='#{@local_storage.id}'][data-local=true]"
    assert_select "select[name='backup[source_storage_id]'] option[value='#{@local_storage.id}']", count: 0
  end

  test "creates local backup and rejects tampered source and path" do
    attributes = { source_storage_id: storages(:source_bucket).id, destination_storage_id: @local_storage.id,
      destination_path: "aws/my-bucket", schedule: "weekly" }
    assert_difference("Backup.count") { post backups_url, params: { backup: attributes } }
    assert_redirected_to backup_url(Backup.last)
    assert_no_difference("Backup.count") do
      post backups_url, params: { backup: attributes.merge(destination_path: "../../etc") }
    end
    assert_response :unprocessable_entity
    assert_no_difference("Backup.count") do
      post backups_url, params: { backup: attributes.merge(source_storage_id: @local_storage.id) }
    end
    assert_response :unprocessable_entity
  end

  test "local provider bucket endpoints do not invoke rclone or import storages" do
    Open3.stub :capture3, ->(*) { flunk "must not discover local buckets" } do
      get provider_buckets_url(@local_provider)
      assert_response :unprocessable_entity
      assert_no_difference("Storage.count") do
        post provider_buckets_url(@local_provider), params: { bucket_name: "../../etc" }
      end
      assert_response :unprocessable_entity
    end
  end

  test "local storage views render the root and destination-only editing" do
    get storage_url(@local_storage)
    assert_response :success
    assert_select "dt", text: "Base path"
    get edit_storage_url(@local_storage)
    assert_response :success
    assert_select "input[name='storage[bucket_name]']", count: 0
    assert_select "input[name='storage[usage_type]']", count: 0
  end
end
