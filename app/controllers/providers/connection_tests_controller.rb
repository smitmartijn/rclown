module Providers
  class ConnectionTestsController < ApplicationController
    include ProviderScoped

    def create
      if @provider.supports_bucket_discovery?
        @provider.discover_buckets
      else
        Provider::LocalPath.new(@provider.base_path).root!
      end
      @success = true
      @message = "Connection successful"
    rescue Rclone::Error => e
      @success = false
      @message = e.message
    end
  end
end
