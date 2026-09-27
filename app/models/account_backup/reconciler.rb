class AccountBackup::Reconciler
  class Stopped < StandardError; end

  def initialize(run)
    @run = run
    @account = run.account_backup
  end

  def call(names)
    rows = names.map do |name|
      @run.touch
      @account.with_lock do
        @account.touch
        ensure_current!
        if @run.preview?
          describe(name)
        else
          reconcile(name)
        end
      end
    end
    unless @run.preview?
      @account.with_lock do
        @account.touch
        ensure_current!
        @account.buckets.where.not(bucket_name: names).find_each do |bucket|
          bucket.update!(available: false)
          rows << row(bucket.bucket_name, "missing", "Bucket no longer visible; existing backup and files are preserved", bucket.backup)
        end
      end
    end
    rows
  end

  # Explicitly choosing a different existing destination must still satisfy the
  # whole-bucket and destination safety rules.
  def link_existing!(bucket, backup)
    @account.with_lock do
      @account.touch
      raise Rclone::Error, "Bucket already has a managed backup; detach it first" if bucket.reload.backup_id
      unless backup.source_storage.provider_id == @account.source_provider_id && backup.source_storage.bucket_name == bucket.bucket_name && backup.source_path.blank?
        raise Rclone::Error, "Choose a whole-bucket backup for this source bucket"
      end
      raise Rclone::Error, "Backup already belongs to an account" if backup.account_backup_bucket
      backup.account_backup_candidate = true
      backup.validate!
      bucket.update!(backup: backup, last_error: nil, resolution: nil)
    end
  end

  private
    def ensure_current!
      raise Stopped, "Discovery was superseded" unless @run.reload.running?
      raise Stopped, "Discovery is paused" unless @run.preview? || (@account.active? && @account.discovery_enabled?)
    end

    def describe(name)
      membership = @account.buckets.find_by(bucket_name: name)
      if rule = @account.exclusion_for(name)
        return row(name, "excluded", "Matched rule: #{rule}", membership&.backup)
      end
      return row(name, "existing", nil, membership.backup) if membership&.backup

      path = @account.child_path(name)
      source = @account.source_provider.storages.find_by(bucket_name: name) || @account.source_provider.storages.build(bucket_name: name)
      raise Rclone::Error, "Source storage is restricted to destination usage" unless source.available_as_source?
      existing = source.persisted? ? source.source_backups.to_a : []
      matches = existing.select do |backup|
        backup.source_path.blank? && backup.destination_storage_id == @account.destination_storage_id && backup.destination_path.to_s == path
      end
      if matches.one? && matches.first.account_backup_bucket.nil?
        candidate = matches.first
        action = "link"
      elsif existing.any? && membership&.resolution != "create"
        return row(name, "conflict", "Existing backups differ or are ambiguous. Link a whole-bucket backup, create another, or exclude this bucket.")
      else
        candidate = Backup.new(@account.backup_defaults.merge(source_storage: source, destination_storage: @account.destination_storage, destination_path: path))
        action = "create"
      end
      candidate.account_backup_candidate = true
      candidate.validate!
      row(name, action, nil, candidate)
    rescue ActiveRecord::RecordInvalid, Rclone::Error => e
      row(name, "error", @run.safe_error(e))
    end

    def reconcile(name)
      bucket = @account.buckets.find_or_create_by!(bucket_name: name)
      bucket.update!(available: true, last_seen_at: Time.current)
      result = describe(name)
      case result["action"]
      when "create", "link"
        begin
          # A savepoint rolls back a source import if destination validation
          # fails, without losing the per-bucket error/inventory record.
          Backup.transaction(requires_new: true) do
            source = @account.source_provider.storages.find_or_create_by!(bucket_name: name)
            backup = if result["action"] == "link"
              Backup.find(result.fetch("backup_id"))
            else
              Backup.new(@account.backup_defaults.merge(source_storage: source, destination_storage: @account.destination_storage, destination_path: @account.child_path(name)))
            end
            backup.account_backup_candidate = true
            backup.save!
            bucket.update!(backup: backup, resolution: nil, last_error: nil)
            # after_all_transactions_commit also waits for the enclosing account
            # transaction; the regular scheduler recovers a crash before enqueue.
            if result["action"] == "create" && backup.enabled?
              ActiveRecord.after_all_transactions_commit { backup.execute(scheduled: true) }
            end
            result = row(name, result["action"] == "create" ? "created" : "linked", nil, backup)
          end
        rescue ActiveRecord::RecordInvalid, Rclone::Error => e
          result = row(name, "error", @run.safe_error(e))
        end
      end
      bucket.update!(last_error: %w[error conflict].include?(result["action"]) ? result["message"] : nil)
      result
    end

    def row(name, action, message = nil, backup = nil)
      { "bucket_name" => name, "action" => action, "message" => message,
        "backup_id" => backup&.id, "destination" => backup&.destination_full_path || proposed_destination(name) }
    end

    def proposed_destination(name)
      "#{@account.destination_storage.root_name}/#{@account.child_path(name)}"
    rescue Rclone::Error
      nil
    end
end
