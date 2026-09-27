## Deploying with Docker

We provide pre-built Docker images that can be used to run Rclown on your own server.

If you don't need to change the source code, and just want the out-of-the-box Rclown experience, this can be a great way to get started.

You'll find the latest version of Rclown's Docker image at `ghcr.io/marckohlbrugge/rclown:main`.
To run it you'll need three things: a machine that runs Docker; a mounted volume (so that your database is stored somewhere that is kept around between restarts); and some environment variables for configuration.

### Mounting a storage volume

The standard Rclown setup keeps all of its storage inside the path `/rails/storage`.
By default Docker containers don't persist storage between runs, so you'll want to mount a persistent volume into that location.

The simplest way to do this is with the `--volume` flag with `docker run`. For example:

```sh
docker run --volume rclown:/rails/storage ghcr.io/marckohlbrugge/rclown:main
```

That will create a named volume (called `rclown`) and mount it into the correct path.
Docker will manage where that volume is actually stored on your server.

You can also specify the data location yourself, mount a network drive, and more.
Check the Docker documentation to find out more about what's available.

### Configuring with environment variables

To configure your Rclown installation, you can use environment variables.
Many of these are optional, but at a minimum you'll want to configure your secret key.

#### Secret Key Base

Various features inside Rclown rely on cryptography to work.
To set this up, you need to provide a secret value that will be used as the basis of those secrets.
This value can be anything, but it should be unguessable, and specific to your instance.

You can generate a random key with:

```sh
openssl rand -hex 64
```

Once you have one, set it in the `SECRET_KEY_BASE` environment variable:

```sh
docker run --environment SECRET_KEY_BASE=abcdefabcdef ...
```

#### SSL

By default, Rclown assumes it's running behind an SSL-terminating proxy and enforces HTTPS.

If you're running Rclown behind a reverse proxy that handles SSL (like Cloudflare, nginx, or Caddy), you don't need to change anything.

If you aren't using SSL at all (for example, if you want to run it locally on your laptop) then you should specify `DISABLE_SSL=true`:

```sh
docker run --publish 80:80 --environment DISABLE_SSL=true ...
```

#### HTTP Basic Auth

Rclown should be protected with HTTP Basic Authentication. This is required for production deployments to prevent unauthorized access to your backup configurations and credentials.

Set the `HTTP_AUTH_USERNAME` and `HTTP_AUTH_PASSWORD` environment variables:

```sh
docker run \
  --environment HTTP_AUTH_USERNAME=admin \
  --environment HTTP_AUTH_PASSWORD=your-secure-password \
  ...
```

When both variables are set, Rclown will require authentication to access the dashboard.

#### Email Notifications

Rclown can send email notifications when backups fail. Configure SMTP settings via Rails credentials or environment variables:

```sh
docker run \
  --environment NOTIFICATION_EMAIL=alerts@example.com \
  ...
```

SMTP settings should be configured in your Rails credentials file.

## Example

Here's an example of a `docker-compose.yml` that you could use to run Rclown via `docker compose up`:

```yaml
services:
  web:
    image: ghcr.io/marckohlbrugge/rclown:main
    restart: unless-stopped
    ports:
      - "80:80"
    environment:
      - SECRET_KEY_BASE=your-secret-key-here
      - HTTP_AUTH_USERNAME=admin
      - HTTP_AUTH_PASSWORD=your-secure-password
      - DISABLE_SSL=true
    volumes:
      - rclown:/rails/storage

volumes:
  rclown:
```

For production with SSL handled by a reverse proxy:

```yaml
services:
  web:
    image: ghcr.io/marckohlbrugge/rclown:main
    restart: unless-stopped
    ports:
      - "80:80"
    environment:
      - SECRET_KEY_BASE=your-secret-key-here
      - HTTP_AUTH_USERNAME=admin
      - HTTP_AUTH_PASSWORD=your-secure-password
    volumes:
      - rclown:/rails/storage

volumes:
  rclown:
```

## Back up cloud buckets to a NAS / local filesystem

Build an image from the checkout containing local destination support (an older
published image will not contain this feature). From that checkout, create a
`compose.yaml`:

```yaml
services:
  web:
    build: .
    image: rclown-local:latest
    restart: unless-stopped
    ports:
      - "8080:80"
    environment:
      SECRET_KEY_BASE: ${SECRET_KEY_BASE:?Set SECRET_KEY_BASE}
      HTTP_AUTH_USERNAME: ${HTTP_AUTH_USERNAME:-admin}
      HTTP_AUTH_PASSWORD: ${HTTP_AUTH_PASSWORD:?Set HTTP_AUTH_PASSWORD}
      ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY: ${ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY:?Set encryption primary key}
      ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY: ${ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY:?Set encryption deterministic key}
      ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT: ${ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT:?Set encryption salt}
      SOLID_QUEUE_IN_PUMA: "true"
      DISABLE_SSL: "true"
    volumes:
      - ./storage:/rails/storage
      - type: bind
        source: /volume1/backups/cloud-storage-backups
        target: /backups
        bind:
          create_host_path: false
```

The long bind syntax prevents Docker from silently creating a missing host
backup directory. Its short equivalent is
`/volume1/backups/cloud-storage-backups:/backups`. Another example is
`/volume1/backups/object-storage:/backups`.

1. Prepare **dedicated** directories on the Docker host:

   ```sh
   mkdir -p ./storage /volume1/backups/cloud-storage-backups
   sudo chown 1000:1000 ./storage /volume1/backups/cloud-storage-backups
   sudo chmod 750 ./storage /volume1/backups/cloud-storage-backups
   ```

   The image runs as UID/GID `1000:1000`. NAS ACLs must also allow that identity
   to read, write, list and traverse the mounted directories. Existing backup
   contents must be accessible too. Grant equivalent NAS ACLs if changing
   ownership is inappropriate. Do not use a directory shared with unrelated
   data or untrusted writers.

2. Create a private `.env` file beside `compose.yaml`. Set the five secrets
   below to separate values generated with `openssl rand -hex 32`, and choose
   your login. Keep these values persistent and back them up securely:

   ```dotenv
   SECRET_KEY_BASE=replace-with-generated-secret
   HTTP_AUTH_USERNAME=admin
   HTTP_AUTH_PASSWORD=replace-with-strong-password
   ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=replace-with-generated-secret
   ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=replace-with-generated-secret
   ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=replace-with-generated-secret
   ```

   Run `chmod 600 .env`. For an existing installation, **reuse its existing
   encryption keys and secret**; replacing encryption keys makes stored cloud
   credentials unreadable. Preserve its existing `/rails/storage` volume too.

3. Run `docker compose up -d --build`. The entrypoint runs normal database
   migrations, including the new provider base-path column. The in-process
   Solid Queue worker runs backups, notifications, the existing scheduler and
   daily retention cleanup. Separate workers must have the same `/backups`
   mount and permissions.

4. Open `http://NAS-HOST:8080` and log in. This example is for a trusted LAN.
   Behind an HTTPS reverse proxy, remove `DISABLE_SSL` and configure the proxy
   as for an ordinary Rclown deployment.

5. Create a provider named **Local NAS**, type **Local Filesystem**, base path
   **`/backups`**. Rclown automatically creates its destination-only root
   storage. No keys or bucket import are required for this provider.

6. Configure/import your cloud source bucket as usual. Create a backup, choose
   the cloud bucket as Source and **Local NAS** as Destination, and enter
   **`cloudflare/my-bucket`** as Destination Path. Choose a daily or weekly
   schedule and run a dry run before the first backup.

The path mapping is:

| Location | Path |
| --- | --- |
| Docker host | `/volume1/backups/cloud-storage-backups` |
| Container and provider Base path | `/backups` |
| Backup Destination Path | `cloudflare/my-bucket` |
| Result inside container | `/backups/cloudflare/my-bucket` |
| Result on NAS | `/volume1/backups/cloud-storage-backups/cloudflare/my-bucket` |

Rclown sees the **container path**, never the host path. Use distinct destination
paths for different backups, for example `aws/my-bucket` and
`backblaze/my-bucket`. Because backups use `sync`, unrelated files in a chosen
destination can be moved into retention.

### Local path safety and errors

- The base must already exist, be an absolute directory, and be readable,
  writable and searchable by the Rclown process. `/` is rejected. Configure a
  canonical path without symlinks (including symlinks in its parents).
- A backup requires a nonempty relative path beneath that root. Absolute paths,
  dot segments (`.` / `..`), backslashes, empty path components, control
  characters and the reserved top-level `.deleted` directory are rejected.
  Spaces and shell punctuation are supported; process arguments are passed
  separately without a shell.
- Existing target components are checked when saving and resolving paths.
  Before sync and cleanup, Rclown also walks the target and retention trees and
  rejects symlinks (even internal/dangling links), hard-linked files and special
  files. Final subdirectories need not exist; rclone creates them.
- Use a dedicated mount controlled by Rclown. Preflight checks cannot prevent
  another process from swapping a directory for a symlink or changing mounts
  **while rclone is running**. Do not expose this directory to untrusted writers
  or enable rclone link-following options through environment overrides. The
  tree scan adds filesystem work proportional to existing backup contents.
- Filesystem mount health remains the host administrator's responsibility. An
  unmounted NAS share that leaves a writable directory behind cannot be
  distinguished from intentional local storage. Ensure the NAS volume is
  mounted before starting the container.
- Configuration errors appear on the forms. Missing mounts and permissions
  failures during runs appear in backup history/logs and use the normal failure
  notifications. Cleanup failures appear in application logs; an unsafe local
  target is skipped so other backups can still be cleaned.

See [retention behavior](backup-retention.md#local-filesystem-destinations) for
local archive layout and the existing modification-time retention semantics.
