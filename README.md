# ZFS Snapshot Latest Mount

A bash script that mounts the latest ZFS snapshot for configured datasets to a static path, ensuring that external backup tools always operate on a consistent, point-in-time snapshot — not on live data that could change mid-backup.

## The Problem

When backing up data from a running application (Nextcloud, Immich, etc.), the backup reads **live data** that is actively being modified. This creates a fundamental issue:

- **Inconsistent backup state** — Files change while the backup is running. A data might be halfway through a write, or a file might be deleted between the time the backup reads the directory and the time it reads the file
- **No atomicity guarantee** — There's no way to ensure the backup represents a single consistent moment in time.

ZFS snapshots solve this — they are **atomic, point-in-time** copies of the filesystem. But accessing snapshot data from inside Docker containers is not straightforward (see [Docker Bind Mount Caveat](#docker-bind-mount-caveat)).

## The Solution

This script:

1. Finds the latest ZFS snapshot for each configured dataset
2. Mounts it to a **static, predictable path** on the host
3. Restarts Docker containers that need access to the data
4. Reports results via logging and Uptime Kuma
5. Sends an error status to email via Truenas cron error

The backup container (e.g., ZeroByte) then reads from the snapshot mount — **static, consistent data that cannot change during the backup process**.

```
Live dataset:     tank/nextcloud          →  actively changing, NOT safe for backup
Snapshot mount:   /mnt/tank/snapshot-mounts/nextcloud-latest  →  immutable, safe for backup
```

## Docker Bind Mount Caveat

When a snapshot is unmounted and a new one is mounted at the same host path, Docker containers **do not see the change** automatically. The container's bind mount still references the old mount's inode.

## Configuration

Edit the configuration section at the top of the script:

```bash
# ZFS datasets to process (format: "pool/dataset")
DATASETS=(
    "tank/nextcloud"
    "tank/immich"
)

# Docker containers to restart after mount changes
CONTAINERS=(
    "ix-zerobyte-zerobyte-1"
)

# Log file path
LOG_FILE="/var/log/snapshot-mounts.log"

# Uptime Kuma push URL (leave empty to disable)
# Format: https://uptime-kuma.example.com/api/push/XXXXX
UPTIME_KUMA_URL=""
```

## Usage

### Manual Run

```bash
sudo /root/scripts/zfs-snapshot-latest-mount.sh
```

### Cron Job (TrueNAS SCALE)

Add via **System → Advanced → Cron Jobs**:

| Field | Value |
|-------|-------|
| Command | `/root/scripts/zfs-snapshot-latest-mount.sh` |
| User | `root` |
| Schedule | `0 2 * * *` (daily at 2 AM) |

### Example: ZeroByte Offsite Backup

A typical setup on TrueNAS SCALE:

1. TrueNAS creates regular ZFS snapshots of your datasets (e.g., every day at 00:00)
2. This script runs daily via cron (e.g., at 02:00), mounts the latest snapshot to a static path
3. The [ZeroByte](https://github.com/zerobyte-app/zerobyte) backup container has that path bind-mounted as read-only
4. ZeroByte uploads the snapshot data to offsite/cloud storage

Because ZeroByte reads from the **snapshot mount** (not the live dataset), the backup is always consistent — even if the upload takes hours and the live data changes during that time.

```yaml
services:
  zerobyte:
    image: zerobyte/zerobyte:latest
    volumes:
      # Read-only snapshot mounts — consistent, immutable data
      - /mnt/tank/snapshot-mounts/nextcloud-latest:/backup/nextcloud:ro
      - /mnt/tank/snapshot-mounts/immich-latest:/backup/immich:ro
```

## Mount Path Structure

Snapshots are mounted under a predictable path derived from the dataset name:

```
/mnt/<pool>/snapshot-mounts/<dataset>-latest
```

| Dataset | Mount Path |
|---------|------------|
| `tank/nextcloud` | `/mnt/tank/snapshot-mounts/nextcloud-latest` |
| `tank/immich` | `/mnt/tank/snapshot-mounts/immich-latest` |
| `ssd/postgres` | `/mnt/ssd/snapshot-mounts/postgres-latest` |

## Features

- **Concurrency protection** — uses `flock` to prevent overlapping runs (e.g., from overlapping cron jobs)
- **Skip unchanged mounts** — if the same snapshot is already mounted, no unmount/remount or container restart occurs
- **Read-only mount** — snapshots are always mounted read-only (`-o ro`), matching their inherent immutability
- **Container restart** — containers are restarted only when at least one mount was updated
- **Cron-error friendly output** — success is silent (no email), errors go to stderr (triggers cron email)
- **Detailed error messages** — captures actual command stderr (zfs, mount, docker) and includes it in error output
- **Uptime Kuma push** — reports success with snapshot details or failure with error count
- **Structured logging** — all operations logged to file with timestamps

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Dataset doesn't exist | Error to stderr + log, skip to next dataset |
| No snapshots found | Error to stderr + log, skip to next dataset |
| Unmount fails | Error with command output to stderr + log, skip to next dataset |
| Mount fails (ro) | Error with mount output to stderr + log |
| Another instance running | Error to stderr + log, exit immediately |
| Container restart fails | Error with Docker output to stderr + log |
| Any failure | Exit code 1, Uptime Kuma `status=down` |
| All success | Exit code 0, silent output, Uptime Kuma `status=up` |

## Uptime Kuma Integration

When `UPTIME_KUMA_URL` is set, the script pushes status after each run:

**Success:**
```
2 mounted: nextcloud:2024-01-15, immich:2024-01-15
```

**Failure:**
```
Failed: 2 errors
```

Snapshot dates are extracted from snapshot names using the `YYYY-MM-DD` pattern. If no date is found in the name, the full snapshot name is used.

## Requirements

- TrueNAS SCALE (or any Linux with ZFS)
- `zfs` command-line tool
- `docker` CLI (for container restart)
- `curl` (for Uptime Kuma push, optional)
- Root/sudo privileges (for mount operations)

## License

MIT
