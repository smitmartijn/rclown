class Health::Settings
  class Invalid < StandardError; end

  attr_reader :grace_seconds, :check_max_age_seconds, :heartbeat_seconds

  def initialize
    @grace_seconds = integer("HEALTH_GRACE_PERIOD_SECONDS", 1800, 0..604800)
    @check_max_age_seconds = integer("HEALTH_CHECK_MAX_AGE_SECONDS", 900, 300..86400)
    @heartbeat_seconds = integer("HEALTH_WORKER_HEARTBEAT_SECONDS", 300, 60..3600)
  end

  def as_json(*)
    { grace_period_seconds: grace_seconds, duration_sample_size: 10,
      check_max_age_seconds: check_max_age_seconds, worker_heartbeat_seconds: heartbeat_seconds }
  end

  private
    def integer(name, default, range)
      value = Integer(ENV.fetch(name, default.to_s), 10)
      raise Invalid, "#{name} must be between #{range.min} and #{range.max}" unless range.cover?(value)
      value
    rescue ArgumentError
      raise Invalid, "#{name} must be an integer"
    end
end
