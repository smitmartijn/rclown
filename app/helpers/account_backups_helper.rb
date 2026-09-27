module AccountBackupsHelper
  def known_account_bucket_names(account)
    (account.buckets.pluck(:bucket_name) + Array(account.discovery_runs.order(id: :desc).first&.results).pluck("bucket_name")).uniq.sort
  end

  def account_discovery_action(action)
    { "create" => "Create", "link" => "Use existing", "created" => "Created", "linked" => "Linked",
      "existing" => "Managed", "excluded" => "Excluded", "missing" => "Unavailable",
      "error" => "Needs attention", "conflict" => "Needs attention" }.fetch(action, action.humanize)
  end
end
