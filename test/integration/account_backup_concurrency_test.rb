require "test_helper"
require_relative "../support/local_destination"

class AccountBackupConcurrencyTest < ActiveSupport::TestCase
  include LocalDestination
  self.use_transactional_tests = false

  setup do
    setup_local_destination
    @source = Provider.create!(name: "Concurrency source", provider_type: :amazon_s3, access_key_id: "key", secret_access_key: "secret")
    @account = AccountBackup.create!(source_provider: @source, destination_storage: @local_storage, activated_at: Time.current)
  end

  teardown do
    @account&.destroy!
    Backup.where(destination_storage: @local_storage).find_each(&:destroy!) if @local_storage
    @local_provider&.destroy!
    @source&.destroy!
    teardown_local_destination
  end

  test "simultaneous discovery requests queue only one inventory run" do
    results = simultaneously { AccountBackup.find(@account.id).queue_discovery! }
    assert_equal 1, results.compact.size
    assert_equal 1, @account.discovery_runs.pending.count
  end

  test "simultaneous manual and scheduled executions create only one normal run" do
    results = simultaneously { Backup.find(@local_backup.id).execute }
    assert_equal 1, results.compact.size
    assert_equal 1, @local_backup.runs.pending.count
  end

  test "committed reconciliation queues initial execution and simultaneous scans cannot duplicate backups" do
    runs = 2.times.map { @account.discovery_runs.create!(status: :running, started_at: Time.current) }
    index = Queue.new
    runs.each { |run| index << run.id }
    simultaneously do
      run = AccountBackupDiscoveryRun.find(index.pop)
      run.complete!(AccountBackup::Reconciler.new(run).call([ "concurrent-bucket" ]))
    end
    bucket = @account.buckets.sole
    assert_equal "concurrent-bucket", bucket.bucket_name
    assert bucket.backup
    assert_equal 1, bucket.backup.runs.pending.count
    assert_equal 1, @source.storages.count
  end

  private
    def simultaneously(&block)
      ready = Queue.new
      start = Queue.new
      threads = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            start.pop
            block.call
          end
        end
      end
      2.times { ready.pop }
      2.times { start << true }
      threads.map(&:value)
    end
end
