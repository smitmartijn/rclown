require "application_system_test_case"
require_relative "../support/local_destination"

class LocalDestinationsTest < ApplicationSystemTestCase
  include LocalDestination

  setup { setup_local_destination }
  teardown { teardown_local_destination }

  test "provider fields and destination hints respond to selection" do
    visit new_provider_path
    choose "Local Filesystem", allow_label_click: true
    assert_field "Base path", visible: true
    assert_no_field "Access Key ID", visible: true
    fill_in "Name", with: "Browser NAS"
    fill_in "Base path", with: @local_root
    click_button "Create Provider"
    assert_selector "h1", text: "Browser NAS"
    assert_text @local_root

    visit new_provider_path
    choose "Local Filesystem", allow_label_click: true
    choose "Amazon S3", allow_label_click: true
    assert_field "Access Key ID", disabled: false
    assert_no_field "Base path", visible: true

    visit new_backup_path
    assert_no_selector "#backup_source_storage_id option", text: "Local NAS"
    select "Local NAS (Local NAS)", from: "Destination"
    assert_selector "#backup_destination_path[required]"
    assert_text "Required relative path beneath the provider base directory"
    select "my-source-bucket (Cloudflare R2)", from: "Source"
    fill_in "Destination Path", with: "cloudflare/browser bucket"
    click_button "Create Backup"
    assert_selector "h1", text: "my-source-bucket → Local NAS"
    assert_text "#{@local_root}/cloudflare/browser bucket"
  end
end
