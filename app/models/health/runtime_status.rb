class Health::RuntimeStatus
  REQUIRED_QUEUES = %w[backups scheduler health].freeze
  REQUIRED_TASKS = %w[schedule_backups discover_account_buckets check_backup_health].freeze

  def initialize(settings:, now:)
    @settings, @now = settings, now
  end

  def call
    result = { status: "healthy", codes: [], database: "healthy", rclone: rclone_available? ? "healthy" : "error" }
    result[:codes] << "rclone_missing" if result[:rclone] == "error"
    result[:queue] = queue_status
    result[:codes].concat(result[:queue][:codes])
    result[:status] = result[:codes].empty? ? "healthy" : "error"
    result
  end

  def queue_status
    processes = SolidQueue::Process.where(last_heartbeat_at: (@now - @settings.heartbeat_seconds)..).to_a
    workers = processes.select { |process| process.kind == "Worker" }
    queues = workers.flat_map { |process| process.metadata.fetch("queues", "").split(",") }
    missing_queues = REQUIRED_QUEUES.reject { |queue| queues.any? { |pattern| File.fnmatch?(pattern, queue) } }
    schedulers = processes.select { |process| process.kind == "Scheduler" }
    tasks = schedulers.flat_map { |process| Array(process.metadata["recurring_schedule"]) }
    missing_tasks = REQUIRED_TASKS - tasks
    paused = SolidQueue::Pause.where(queue_name: REQUIRED_QUEUES).pluck(:queue_name)
    codes = []
    codes << "workers_missing" if missing_queues.any?
    codes << "scheduler_missing" if schedulers.empty?
    codes << "recurring_tasks_missing" if missing_tasks.any?
    codes << "dispatcher_missing" unless processes.any? { |process| process.kind == "Dispatcher" }
    codes << "queues_paused" if paused.any?
    { status: codes.empty? ? "healthy" : "error", codes: codes,
      live_workers: workers.size, missing_queues: missing_queues, missing_recurring_tasks: missing_tasks,
      paused_queues: paused, latest_heartbeat_at: processes.map(&:last_heartbeat_at).max }
  rescue StandardError => e
    Rails.logger.warn "Health queue check failed: #{e.class}"
    { status: "error", codes: [ "queue_unavailable" ] }
  end

  private
    def rclone_available?
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
        path = File.join(directory, "rclone")
        File.file?(path) && File.executable?(path)
      end
    end
end
