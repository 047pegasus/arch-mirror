#!/usr/bin/env bash
# Arch Linux mirror sync script
# Run via systemd timer on host (not in container)
# Reads configuration from /srv/apps/arch-mirror/.env (if exists)
#
# NOTE: bash (not sh) is required — the script uses PIPESTATUS to capture
# the rsync exit code through the tee pipe. The server is Arch so bash
# is always present; the alpine rsync profile container uses `sh /sync.sh`
# only for manual runs where PIPESTATUS is also supported by busybox ash?
# No — so prefer running this on the host via systemd (the supported path).

set -euo pipefail

MIRROR_ROOT="/srv/http/archlinux"
LOG_FILE="/var/log/arch-mirror-sync.log"
LOCK_FILE="/var/lock/arch-mirror-sync.lock"
RSYNC_EXCLUDE="/srv/apps/arch-mirror/rsync-exclude.txt"
ENV_FILE="/srv/apps/arch-mirror/.env"

# Load environment variables from .env if present
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

# Official Arch Linux rsync mirrors: https://archlinux.org/mirrors/
MIRROR_SOURCE="${MIRROR_SOURCE:-rsync://mirror.rackspace.com/archlinux/}"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Lock to prevent concurrent runs
exec 200>"$LOCK_FILE"
flock -n 200 || {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync already running, exiting" >> "$LOG_FILE"
    exit 1
}

echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting sync from $MIRROR_SOURCE" >> "$LOG_FILE"

# Run rsync with --delete-after to avoid partial deletions visible to users
rsync -avhH --delete-after --delay-updates --safe-links \
    --exclude-from="$RSYNC_EXCLUDE" \
    --log-file="$LOG_FILE" \
    --stats \
    "$MIRROR_SOURCE" "$MIRROR_ROOT/" 2>&1 | tee -a "$LOG_FILE"

SYNC_EXIT=${PIPESTATUS[0]}

if [ $SYNC_EXIT -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync completed successfully" >> "$LOG_FILE"
    # Update mirror status file
    echo "last_sync: $(date -Iseconds)" > "$MIRROR_ROOT/mirror-status.txt"
    echo "status: success" >> "$MIRROR_ROOT/mirror-status.txt"
    echo "source: $MIRROR_SOURCE" >> "$MIRROR_ROOT/mirror-status.txt"
elif [ $SYNC_EXIT -eq 24 ]; then
    # Exit 24 = "some files vanished before they could be transferred".
    # Normal on a live upstream: Rackspace rotates packages mid-sync, so files
    # listed at file-list time are gone by transfer time. Everything fetched
    # is intact; the next run reconciles the churn. Not a failure.
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync completed successfully (exit 24: upstream churn, harmless)" >> "$LOG_FILE"
    echo "last_sync: $(date -Iseconds)" > "$MIRROR_ROOT/mirror-status.txt"
    echo "status: success" >> "$MIRROR_ROOT/mirror-status.txt"
    echo "source: $MIRROR_SOURCE" >> "$MIRROR_ROOT/mirror-status.txt"
    echo "note: exit 24, some upstream files vanished mid-transfer" >> "$MIRROR_ROOT/mirror-status.txt"
    SYNC_EXIT=0
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Sync failed with exit code $SYNC_EXIT" >> "$LOG_FILE"
    echo "last_sync: $(date -Iseconds)" > "$MIRROR_ROOT/mirror-status.txt"
    echo "status: failed" >> "$MIRROR_ROOT/mirror-status.txt"
    echo "exit_code: $SYNC_EXIT" >> "$MIRROR_ROOT/mirror-status.txt"
fi

# Generate mirrorlist fragment for users
# Use configured domain or default
MIRROR_DOMAIN="${MIRROR_DOMAIN:-itanishq.space}"
cat > "$MIRROR_ROOT/mirrorlist.txt" <<EOF
# Arch Linux mirror provided by ${MIRROR_DOMAIN}
# Generated: $(date -Iseconds)
Server = https://arch.${MIRROR_DOMAIN}/\$repo/os/\$arch
Server = https://mirror.${MIRROR_DOMAIN}/\$repo/os/\$arch
EOF

exit $SYNC_EXIT