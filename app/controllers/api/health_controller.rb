module Api
  class HealthController < ActionController::Base
    include Authentication

    def show
      response.headers["Cache-Control"] = "no-store"
      report = Health::Report.new.call
      render json: report, status: report[:status] == "healthy" ? :ok : :service_unavailable
    rescue Health::Settings::Invalid => e
      render json: { schema_version: 1, status: "error", checked_at: Time.current,
        checks: { application: { status: "error", codes: [ "invalid_health_configuration" ], message: e.message } } }, status: :service_unavailable
    end
  end
end
