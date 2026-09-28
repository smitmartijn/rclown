require "application_system_test_case"

class NotifiersTest < ApplicationSystemTestCase
  test "create test and edit a Discord notifier" do
    webhook_url = "https://discord.com/api/webhooks/123456/test-token"
    visit new_notifier_path
    fill_in "Name", with: "Discord alerts"
    choose "Slack", allow_label_click: true
    assert_text "Create an incoming webhook in your Slack workspace settings."
    choose "Discord", allow_label_click: true
    assert_text "Create one in your channel's settings"
    assert_no_text "Create an incoming webhook in your Slack workspace settings."
    fill_in "notifier_webhook_url", with: webhook_url
    check "Backup Successful"
    click_button "Create Notifier"
    assert_selector "h1", text: "Discord alerts"
    assert_text "Configured (token hidden)"
    notifier = Notifiers::Discord.find_by!(name: "Discord alerts")
    assert_equal webhook_url, notifier.webhook_url
    assert notifier.notify_on_success?
    assert notifier.notify_on_failure?

    request = stub_request(:post, "#{webhook_url}?wait=true").to_return(status: 200, body: '{"id":"123"}')
    click_button "Send Test"
    assert_text "Test notification sent successfully"
    assert_requested request

    click_link "Edit"
    assert_field "notifier_webhook_url", with: webhook_url
    fill_in "notifier_webhook_url", with: "#{webhook_url}?thread_id=456"
    uncheck "Backup Successful"
    click_button "Update Notifier"
    assert_selector "h1", text: "Discord alerts"
    notifier.reload
    assert_equal "#{webhook_url}?thread_id=456", notifier.webhook_url
    assert_not notifier.notify_on_success?
    assert notifier.notify_on_failure?
  end

  test "existing Slack notifier webhook stays visible when editing" do
    notifier = notifiers(:slack_notifier)
    visit edit_notifier_path(notifier)
    assert_field "notifier_webhook_url", with: notifier.webhook_url
    assert_text "Create an incoming webhook in your Slack workspace settings."
    assert_no_text "Create one in your channel's settings"
    click_button "Update Notifier"
    assert_selector "h1", text: notifier.name
    assert_equal "https://hooks.slack.com/services/T00/B00/XXX", notifier.reload.webhook_url
  end
end
