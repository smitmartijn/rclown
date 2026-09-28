require "net/http"

module Notifiers
  class Discord < Notifier
    class DeliveryError < StandardError; end

    HOSTS = %w[discord.com discordapp.com canary.discord.com ptb.discord.com].freeze
    validate :validate_webhook_url

    def webhook_url
      parsed_config["webhook_url"]
    end

    def self.config_from_params(params)
      { webhook_url: params[:webhook_url].to_s.strip }.to_json
    end

    def deliver(backup_run, event_type = :failure)
      success = event_type.to_sym == :success
      backup = backup_run.backup
      fields = [
        field("Status", success ? "Success" : "Failed"),
        field("Duration", backup_run.formatted_duration || "N/A"),
        field("Source", backup.source_storage.name),
        field("Destination", backup.destination_storage.name)
      ]
      if success
        size = backup_run.source_bytes && ActiveSupport::NumberHelper.number_to_human_size(backup_run.source_bytes)
        fields << field("Size", size || "N/A")
        fields << field("Objects", backup_run.source_count || "N/A")
      else
        fields << field("Exit code", backup_run.exit_code || "N/A")
      end

      post_message(embeds: [ {
        title: success ? "Backup Successful" : "Backup Failed",
        description: escape_text(backup.name).truncate(1024),
        color: success ? 0x57F287 : 0xED4245,
        fields: fields,
        footer: { text: "Rclown • Run ##{backup_run.id}" },
        timestamp: (backup_run.finished_at || Time.current).utc.iso8601
      } ])
    end

    def test_delivery
      post_message(embeds: [ {
        title: "Rclown Test Notification",
        description: "Your Discord integration is working. Backup notifications will appear in this channel.",
        color: 0x5865F2,
        footer: { text: "Rclown" },
        timestamp: Time.current.utc.iso8601
      } ])
    end

    private
      def webhook_uri
        uri = URI.parse(webhook_url.to_s)
        return unless uri.is_a?(URI::HTTPS) && HOSTS.include?(uri.host) && uri.port == 443 && !uri.userinfo && !uri.fragment
        return unless uri.path.match?(%r{\A/api/(?:v\d+/)?webhooks/\d+/[A-Za-z0-9_-]+/?\z})
        URI.decode_www_form(uri.query.to_s)
        uri
      rescue URI::InvalidURIError, ArgumentError
        nil
      end

      def validate_webhook_url
        errors.add(:config, "must include a valid Discord webhook URL") unless webhook_uri
      end

      def post_message(payload)
        uri = webhook_uri
        raise DeliveryError, "Invalid Discord webhook URL" unless uri

        # Request confirmation of delivery, preserving optional thread_id routing.
        query = URI.decode_www_form(uri.query.to_s).reject { |key, _| key == "wait" }
        uri.query = URI.encode_www_form(query + [ [ "wait", "true" ] ])
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 10
        http.write_timeout = 10
        request = Net::HTTP::Post.new(uri.request_uri)
        request["Content-Type"] = "application/json"
        request.body = payload.merge(allowed_mentions: { parse: [] }).to_json
        response = http.request(request)
        raise DeliveryError, "Discord webhook failed (HTTP #{response.code})" unless response.is_a?(Net::HTTPSuccess)
      rescue DeliveryError
        raise
      rescue StandardError => e
        # Webhook tokens and response bodies must not enter notification history.
        raise DeliveryError, "Discord webhook request failed (#{e.class})", cause: nil
      end

      def field(name, value)
        # Conservative character bounds also accommodate Unicode surrogate pairs.
        { name: name, value: escape_text(value).truncate(500).presence || "N/A", inline: true }
      end

      def escape_text(value)
        value.to_s.gsub(/[\\*_~`|<>\[\]()]/) { |character| "\\#{character}" }
      end
  end
end
