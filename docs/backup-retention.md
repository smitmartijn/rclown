# Backup Retention Strategy

> **Status: Implemented** - We chose Option 1 (`--backup-dir`) with date folders.

## Problem

A simple `rclone copy` or `rclone sync` doesn't handle deleted files well for backup purposes:

- **copy**: Additive only, never removes files. Deleted files remain in backup forever.
- **sync**: Makes destination identical to source. Deleted files are immediately removed from backup.

For proper backups, we want:
1. New files added immediately
2. Deleted files retained for a configurable period (e.g., 30 days) before removal

## Implemented Solution: `--backup-dir` with Date Folders

We use rclone's `--backup-dir` flag to move deleted/overwritten files to a separate directory organized by date.

### How it works

```bash
rclone sync source:bucket dest:bucket/path \
  --backup-dir dest:bucket/.deleted/backups/{backup_id}/{date}/path
```

- New files → copied to destination immediately
- Deleted files → moved to `.deleted/backups/{backup_id}/{date}/{path}/{filename}`
- Each backup has its own `.deleted` subdirectory (isolated retention periods)
- Date folders (not filename suffixes) for cleaner organization and browsing

### Directory Structure

```
bucket/
├── r2/
│   └── my-app/           # actual backup data
│       └── uploads/
│           └── photo.jpg
└── .deleted/
    └── backups/
        └── 5/            # backup ID
            ├── 2026-01-15/
            │   └── r2/my-app/uploads/
            │       └── old-photo.jpg
            └── 2026-01-19/
                └── r2/my-app/uploads/
                    └── deleted-file.jpg
```

### Cleanup

`CleanupDeletedFilesJob` runs periodically to purge old files:

```bash
rclone delete dest:.deleted/backups/{id}/ --min-age {retention_days}d
rclone rmdirs dest:.deleted/backups/{id}/ --leave-root
```

The `--min-age` flag uses file modification time, not folder names or time since deletion; see the caveat below.

### Configuration

- `retention_days` per backup (default: 30)
- Cleanup job handles all enabled backups

## Why Date Folders over Filename Suffixes

Initially we used `--suffix -2026-01-19` which appends dates to filenames. We switched to date folders because:

1. **Cleaner browsing** - Can browse by date in any S3 UI
2. **Easier bulk operations** - Delete entire date folder vs filtering by suffix
3. **No filename pollution** - Original filenames preserved
4. **Simpler mental model** - "Files deleted on Jan 19" vs "files ending in -2026-01-19"

## Local filesystem destinations

A local provider has one automatically created root storage. Each backup must
choose a nonempty relative destination path, keeping live data separate from
retention. No local rclone remote is configured; [rclone accepts filesystem
paths directly](https://rclone.org/local/).

For a base path of `/backups`, backup ID 5 and destination path
`cloudflare/my-bucket`, the commands use:

```sh
rclone sync source:my-bucket /backups/cloudflare/my-bucket \
  --backup-dir /backups/.deleted/backups/5/2026-09-27/cloudflare/my-bucket
rclone delete /backups/.deleted/backups/5 --min-age 30d
rclone rmdirs /backups/.deleted/backups/5 --leave-root
```

The normal config and other execution flags still apply. The same retention
period, scheduling, history, dry runs, verification and notifications apply.
All local targets, including cleanup paths, pass through the same containment
and symlink checks. `.deleted` is reserved and cannot be a live destination.

Retention preserves the existing algorithm: `--min-age` uses **file modification
time**, not the date folder or the time the file was deleted. Local moves
preserve modification times, so an old file moved into retention today may be
removed at the next cleanup. This is not a guarantee of 30 days after deletion.
Also, successive versions of the same file archived on the same date share a
path and can overwrite one another, as with existing cloud destinations. See
[rclone backup-dir semantics](https://rclone.org/docs/#backup-dir-string).
