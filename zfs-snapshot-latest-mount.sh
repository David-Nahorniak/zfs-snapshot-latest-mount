#!/bin/bash
# /root/scripts/zfs-snapshot-latest-mount.sh
#
# Mounts the latest ZFS snapshots to a defined directory structure.
# Ensures backup tools operate on consistent, point-in-time snapshot data
# instead of live data that could change mid-backup.

#══════════════════════════════════════════════════════════════
# CONFIGURATION - Define your datasets
#══════════════════════════════════════════════════════════════

# Format: "pool/dataset"
DATASETS=(
    "tank/nextcloud"
    "tank/immich"
)

# Docker containers to restart after mount changes
# Use container names or IDs
CONTAINERS=(
    "ix-zerobyte-zerobyte-1"
)

# Log file
LOG_FILE="/var/log/snapshot-mounts.log"

# Lock file (prevents concurrent runs)
LOCK_FILE="/var/lock/zfs-snapshot-mounts.lock"

# Uptime Kuma push URL (leave empty to disable)
# Format: https://uptime-kuma.example.com/api/push/XXXXX
UPTIME_KUMA_URL=""

#══════════════════════════════════════════════════════════════
# FUNCTIONS
#══════════════════════════════════════════════════════════════

# Info log - file only (silent for cron)
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Error log - file + stderr (for cron email)
# Optionally accepts a second parameter with command error details
error() {
    local msg="$1"
    local detail="${2:-}"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $msg" >> "$LOG_FILE"
    if [[ -n "$detail" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')]   Detail: $detail" >> "$LOG_FILE"
    fi
    # Output to stderr for cron email - including details
    if [[ -n "$detail" ]]; then
        echo "ERROR: $msg ($detail)" >&2
    else
        echo "ERROR: $msg" >&2
    fi
}

# Restarts Docker containers listed in the CONTAINERS array
# Only called when at least one mount changed (UPDATED > 0)
restart_containers() {
    if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
        log "  No containers to restart"
        return 0
    fi

    log "Restarting Docker containers after mount changes..."

    for container in "${CONTAINERS[@]}"; do
        log "  Restarting container: $container"
        local err
        err=$(docker restart "$container" 2>&1) && {
            log "  ✓ Container $container restarted"
        } || {
            error "Failed to restart container: $container" "$err"
        }
    done
}

#══════════════════════════════════════════════════════════════
# MAIN
#══════════════════════════════════════════════════════════════

# Acquire lock to prevent concurrent execution
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    error "Another instance is already running (lock: $LOCK_FILE)"
    exit 1
fi

log "========================================="
log "Mounting ZFS snapshots"
log "========================================="

UPDATED=0
FAILED=0
MOUNTED_INFO=""   # Collect mounted snapshot info for Uptime Kuma

for dataset in "${DATASETS[@]}"; do
    # Split dataset into pool and dataset_name
    POOL="${dataset%%/*}"
    DATASET_NAME="${dataset#*/}"
    
    # Determine paths automatically
    MOUNT_DIR="/mnt/$POOL/snapshot-mounts"
    mount_name="${DATASET_NAME}-latest"
    MOUNT_PATH="$MOUNT_DIR/$mount_name"
    
    log "Processing: $dataset"
    
    # Check if dataset exists
    zfs_err=""
    zfs_err=$(zfs list "$dataset" 2>&1) || {
        error "Dataset $dataset does not exist or is inaccessible" "$zfs_err"
        FAILED=$((FAILED + 1))
        continue
    }
    
    # Find the latest snapshot FOR THIS DATASET ONLY
    SNAP_NAME=$(zfs list -t snapshot -o name -S creation "$dataset" 2>/dev/null | tail -n +2 | head -1 | cut -d'@' -f2)
    
    if [[ -z "$SNAP_NAME" ]]; then
        error "No snapshots found for $dataset"
        FAILED=$((FAILED + 1))
        continue
    fi
    
    SNAP_FULL="$dataset@$SNAP_NAME"
    
    # Check which snapshot is currently mounted
    CURRENT_SNAP=""
    if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
        CURRENT_SNAP=$(findmnt -n -o SOURCE "$MOUNT_PATH" 2>/dev/null)
    fi
    
    # Skip if the same snapshot is already mounted
    if [[ "$CURRENT_SNAP" == "$SNAP_FULL" ]]; then
        log "  ≡ $MOUNT_PATH → $SNAP_NAME (unchanged, skipping)"
        # Add to info even when unchanged (still current)
        SNAP_DATE=$(echo "$SNAP_NAME" | grep -oP '\d{4}-\d{2}-\d{2}' | head -1)
        [[ -z "$SNAP_DATE" ]] && SNAP_DATE="$SNAP_NAME"
        MOUNTED_INFO+="${DATASET_NAME}:${SNAP_DATE}, "
        continue
    fi
    
    # Create mount directory (if it doesn't exist)
    mkdir -p "$MOUNT_DIR"
    
    # Unmount existing mount (if present)
    if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
        log "  Unmounting old mount: $MOUNT_PATH"
        umount_err=""
        umount_err=$(umount "$MOUNT_PATH" 2>&1) || {
            error "Failed to unmount $MOUNT_PATH" "$umount_err"
            FAILED=$((FAILED + 1))
            continue
        }
    fi
    
    # Create mount directory
    mkdir -p "$MOUNT_PATH"
    
    # Mount snapshot read-only (ZFS snapshots are inherently read-only;
    # mounting with -o ro is explicit and avoids unnecessary rw attempt)
    mount_err=""
    mount_err=$(mount -t zfs -o ro "$SNAP_FULL" "$MOUNT_PATH" 2>&1) && {
        log "  ✓ $MOUNT_PATH → $SNAP_NAME (read-only)"
        UPDATED=$((UPDATED + 1))
        SNAP_DATE=$(echo "$SNAP_NAME" | grep -oP '\d{4}-\d{2}-\d{2}' | head -1)
        [[ -z "$SNAP_DATE" ]] && SNAP_DATE="$SNAP_NAME"
        MOUNTED_INFO+="${DATASET_NAME}:${SNAP_DATE}, "
    } || {
        error "Failed to mount $SNAP_FULL" "$mount_err"
        FAILED=$((FAILED + 1))
    }
done

log "========================================="
log "Done: $UPDATED mounted, $FAILED failed"
log "========================================="

# Restart containers only if at least one mount changed
if [[ $UPDATED -gt 0 ]]; then
    log "-----------------------------------------"
    log "Mounts changed, restarting containers"
    log "-----------------------------------------"
    restart_containers
else
    log "No mounts changed, containers not restarted"
fi

# Error summary to stderr for cron email (only on failure)
if [[ $FAILED -gt 0 ]]; then
    echo "" >&2
    echo "=========================================" >&2
    echo "ZFS SNAPSHOT MOUNT - FAILED ($FAILED errors)" >&2
    echo "=========================================" >&2
    echo "Check log: $LOG_FILE" >&2
    echo "=========================================" >&2

    # Uptime Kuma - report failure
    if [[ -n "$UPTIME_KUMA_URL" ]]; then
        curl -sS -o /dev/null "${UPTIME_KUMA_URL}?status=down&msg=Failed:${FAILED}_errors" 2>/dev/null
    fi

    exit 1
fi

# Uptime Kuma - report success
if [[ -n "$UPTIME_KUMA_URL" ]]; then
    # Remove trailing comma and space from MOUNTED_INFO
    MOUNTED_INFO="${MOUNTED_INFO%, }"
    curl -sS -o /dev/null -G "$UPTIME_KUMA_URL" \
        --data-urlencode "status=up" \
        --data-urlencode "msg=${UPDATED} mounted: ${MOUNTED_INFO}" \
        2>/dev/null
fi

exit 0
