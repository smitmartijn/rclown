# Health monitoring API

Poll `GET /api/health` to monitor both Rclown and its backups. The endpoint uses
the same `HTTP_AUTH_USERNAME` and `HTTP_AUTH_PASSWORD` as the web interface. If
web authentication is not configured, this endpoint is also unauthenticated.
Responses are JSON with `Cache-Control: no-store`.

```sh
curl --user 'monitor:your-password' https://rclown.example.com/api/health
```

| Overall status | HTTP status | Meaning |
| --- | --- | --- |
| `healthy` | 200 | No monitored failures, missed deadlines, or infrastructure issues |
| `warning` | 503 | A backup/discovery is overdue, buckets need attention, or connection checks are missing/stale |
| `error` | 503 | A backup/discovery failed, a fresh connection check failed, or app infrastructure is unavailable |

Configure your monitor to alert on a non-200 response, or inspect `status` to
distinguish warnings from errors. `/up` remains the lightweight Rails liveness
endpoint; `/health` remains the human-readable health page.

## Response

The response has `schema_version: 1`, an overall `status`, `checked_at`, effective
`settings`, and these sections:

- `checks.application`: primary database access, availability of the rclone
  executable, and Solid Queue health. Queue checks require fresh worker,
  dispatcher, and scheduler heartbeats, workers subscribed to `backups`,
  `scheduler`, and `health`, no paused required queues, and the recurring tasks
  `schedule_backups`, `discover_account_buckets`, and `check_backup_health`.
- `checks.backups`, `checks.connections`, `checks.account_discovery`: independent
  component statuses. The overall status is the worst component status.
- `summary`: total/monitored/running/failed/missed backup counts.
- `backups`: each backup's status, state, stable reason `code`, last result,
  latest run, last successful completion, expected duration, expected next run,
  overdue deadline, and connection-check results/timestamp.
- `providers`: source/destination targets used by monitored backups, grouped by
  provider, with each target's role, check type, status, code, and check time.
- `account_backups`: discovery failures, missed discovery deadlines, and
  unavailable/conflicting buckets. Drafts and paused discovery are informational.

Run IDs and provider/storage IDs identify the corresponding records in the UI.
The response excludes credentials, raw logs, subprocess output, and provider
configuration. Infrastructure failures can produce a shorter response with an
`error` status and an application reason code.

## Backup timing

A **running or stopping normal backup never becomes unhealthy because of its
duration**. A running retry also suppresses the previous failed result until it
finishes. Independent infrastructure or provider problems may still affect the
overall status. A queued retry does not suppress an unresolved failure.

Only real backups count: dry runs cannot satisfy a schedule, extend a deadline,
clear a failure, or hide an overdue backup. Disabled backups and buckets
explicitly excluded by account rules are not monitored. An enabled backup held
because its source bucket disappeared reports `source_bucket_missing`.

For an existing successful backup:

```text
expected duration = longest duration of the last 10 successful normal runs
next expected run = later of (last successful run's creation + schedule interval)
                            and (that run's completion)
overdue deadline  = next expected run + expected duration + grace period
```

The schedule interval is one day or one week, matching the app's rolling
schedule. Using completion as a lower bound accommodates backups that take
longer than their schedule interval. A backup becomes missed strictly after
the deadline, not at it.

For a backup with no successful history, the first run is due immediately from
its creation, with the grace period allowed before alerting. Its estimated
duration is zero until it has a successful sample; once running, it does not
alert regardless of duration. Queuing new attempts or cancelling/skipping runs
does not continually push back the successful-backup deadline. Cancellations
alone are not failures. A failed normal backup alerts immediately until a
successful normal run or an active retry supersedes it.

Account discovery uses the same grace/duration principle, its configured
discovery interval, and its activation time for the first discovery. Preview
runs never satisfy scheduled discovery.

## Provider and destination checks

A recurring scheduler queues checks every five minutes for monitored backups.
HTTP requests read stored results; polling the API never contacts cloud
providers or writes to a destination. A dedicated scheduler/health worker in
`config/queue.yml` keeps these tasks moving while backup threads are occupied.
Custom worker deployments must also consume the `health` queue and allow the
`check_backup_health` recurring task.

Cloud checks use a read-only rclone listing of a random, nonexistent sub-prefix
beneath the configured source/destination path. This checks bucket-scoped
connectivity and listing permissions without enumerating the backup's objects
or requiring account-wide bucket discovery permission. Object-store prefixes
may be empty or absent; absence of this probe prefix is expected. The cloud
process has a 15-second timeout, followed by bounded termination if needed.
See [rclone listing behavior](https://rclone.org/commands/rclone_lsjson/).

`cloud_list_accessible` does **not** prove cloud write/delete permission or
verify backed-up contents. Real backup and verification outcomes provide that
additional evidence. No cloud probe objects are created. Local checks validate
destination paths and make a small temporary write in the configured base
directory, flush it, and remove it. This catches missing, read-only, or full
destinations; it does not prove that an unexpectedly replaced but writable
mount is the intended physical device.

Connection results are invalidated when paths, storage roles, or provider
configuration change. Results older than the configured maximum age become a
warning. New backups get their startup grace before a missing first check warns.
Checks expose fixed reason codes, including `cloud_list_failed`,
`connection_timeout`, `connection_check_failed`, `usage_not_allowed`,
`configuration_changed`, `check_stale`, and `not_checked`.

## Configuration

| Environment variable | Default | Allowed range |
| --- | --- | --- |
| `HEALTH_GRACE_PERIOD_SECONDS` | 1800 (30 minutes) | 0–604800 |
| `HEALTH_CHECK_MAX_AGE_SECONDS` | 900 (15 minutes) | 300–86400 |
| `HEALTH_WORKER_HEARTBEAT_SECONDS` | 300 (5 minutes) | 60–3600 |

Invalid settings produce an `invalid_health_configuration` error response.
Deploy the database migration and restart the web and job processes together.
In the standard Docker image the entrypoint applies the migration; keep
`SOLID_QUEUE_IN_PUMA=true` when running the workers in the web container.
