require "test_helper"

module Notifiers
  class DiscordTest < ActiveSupport::TestCase
    setup do
      @url = "https://discord.com/api/webhooks/123456/test-token"
      @notifier = Discord.new(name: "Discord alerts", config: { webhook_url: @url }.to_json)
    end

    test "builds a Discord notifier with trimmed encrypted configuration" do
      notifier = Notifier.build(ActionController::Parameters.new(
        type: "Notifiers::Discord", name: "Discord", webhook_url: " #{@url} \n"
      ))
      assert_instance_of Discord, notifier
      assert_equal "Discord", notifier.type_name
      notifier.save!
      assert_equal @url, notifier.reload.webhook_url
      assert_not_includes notifier.ciphertext_for(:config), "test-token"
    end

    test "accepts standard legacy and versioned Discord URLs" do
      [ @url, "https://discordapp.com/api/webhooks/123/token", "https://canary.discord.com/api/v10/webhooks/123/token_abc-123?thread_id=456" ].each do |url|
        @notifier.config = { webhook_url: url }.to_json
        assert @notifier.valid?, url
      end
    end

    test "rejects missing malformed and non-Discord webhook URLs" do
      [ nil, "invalid url", @url.sub("https:", "http:"), @url.sub("discord.com", "discord.com.example.com"),
        @url.sub("discord.com", "discord.com:8443"), @url.sub("discord.com", "user@discord.com"),
        "https://discord.com/channels/123", "#{@url}/slack", "#{@url}#fragment" ].each do |url|
        @notifier.config = { webhook_url: url }.to_json
        assert_not @notifier.valid?, url.inspect
        assert_includes @notifier.errors[:config], "must include a valid Discord webhook URL"
      end
    end

    test "failure embed includes backup details without logs or mentions" do
      run = backup_runs(:failed_run)
      run.backup.name = "Backup *important* @everyone"
      run.define_singleton_method(:raw_log) { "secret log content" }
      payload = capture_delivery { @notifier.deliver(run) }
      embed = payload.fetch("embeds").sole
      fields = embed.fetch("fields").to_h { |field| [ field["name"], field["value"] ] }
      assert_equal "Backup Failed", embed["title"]
      assert_equal 0xED4245, embed["color"]
      assert_equal "Backup \\*important\\* @everyone", embed["description"]
      assert_equal "Failed", fields["Status"]
      assert_equal "1", fields["Exit code"]
      assert_equal run.formatted_duration, fields["Duration"]
      assert_equal run.backup.source_storage.name, fields["Source"]
      assert_equal run.backup.destination_storage.name, fields["Destination"]
      assert_equal run.finished_at.utc.iso8601, embed["timestamp"]
      assert_equal({ "parse" => [] }, payload["allowed_mentions"])
      assert_not_includes payload.to_json, "secret log content"
    end

    test "success embed uses size and object count from the delivered run" do
      run = backup_runs(:successful_run)
      run.source_bytes = 2048
      run.source_count = 0
      payload = capture_delivery { @notifier.deliver(run, :success) }
      embed = payload.fetch("embeds").sole
      fields = embed.fetch("fields").to_h { |field| [ field["name"], field["value"] ] }
      assert_equal "Backup Successful", embed["title"]
      assert_equal 0x57F287, embed["color"]
      assert_equal "2 KB", fields["Size"]
      assert_equal "0", fields["Objects"]
      assert_not fields.key?("Exit code")
    end

    test "long Unicode names fit Discord embed limits" do
      run = backup_runs(:failed_run)
      run.backup.name = "📦" * 5000
      run.backup.source_storage.display_name = "📦" * 5000
      run.backup.destination_storage.display_name = "📦" * 5000
      embed = capture_delivery { @notifier.deliver(run) }.fetch("embeds").sole
      assert_operator embed["description"].encode("UTF-16LE").bytesize / 2, :<=, 4096
      embed["fields"].each do |field|
        assert_operator field["value"].encode("UTF-16LE").bytesize / 2, :<=, 1024
      end
    end

    test "test message preserves thread routing and requests delivery confirmation" do
      @notifier.config = { webhook_url: "#{@url}?thread_id=456&wait=false" }.to_json
      payload = capture_delivery(url: "#{@url}?thread_id=456&wait=true") { @notifier.test_delivery }
      assert_equal "Rclown Test Notification", payload.fetch("embeds").sole["title"]
      assert_equal({ "parse" => [] }, payload["allowed_mentions"])
    end

    test "HTTP failures report status without disclosing response bodies" do
      [ 400, 401, 404, 429, 500 ].each do |status|
        stub_request(:post, "#{@url}?wait=true").to_return(status: status, body: "secret-token")
        error = assert_raises(Discord::DeliveryError) { @notifier.test_delivery }
        assert_equal "Discord webhook failed (HTTP #{status})", error.message
      end
    end

    test "network failures do not disclose webhook tokens" do
      stub_request(:post, "#{@url}?wait=true").to_raise(Net::ReadTimeout.new(@url))
      error = assert_raises(Discord::DeliveryError) { @notifier.test_delivery }
      assert_equal "Discord webhook request failed (Net::ReadTimeout)", error.message
      assert_nil error.cause
    end

    private

    def capture_delivery(url: "#{@url}?wait=true")
      payload = nil
      request = stub_request(:post, url).with(headers: { "Content-Type" => "application/json" }) do |req|
        payload = JSON.parse(req.body)
        true
      end.to_return(status: 200, body: '{"id":"123"}')
      yield
      assert_requested request
      payload
    end
  end
end
