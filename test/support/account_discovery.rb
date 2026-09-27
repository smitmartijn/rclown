require_relative "local_destination"

module AccountDiscovery
  include LocalDestination

  def setup_account_discovery
    setup_local_destination
    @account = AccountBackup.create!(source_provider: providers(:cloudflare), destination_storage: @local_storage,
      activated_at: Time.current, backups_enabled: false)
  end

  def reconcile_buckets(names, preview: false, account: @account)
    run = account.discovery_runs.create!(status: :running, preview: preview, started_at: Time.current)
    callbacks = []
    ActiveRecord.stub :after_all_transactions_commit, ->(&block) { callbacks << block } do
      run.complete!(AccountBackup::Reconciler.new(run).call(names))
    end
    callbacks.each(&:call)
    run
  end
end
