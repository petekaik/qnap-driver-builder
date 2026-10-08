#!/bin/sh
# Watchdog for the module loader. Runs every 5 minutes from cron, installed by
# qnap-install.sh as /etc/config/user_cmd/dvb-watchdog.cron.
#
# Recovers from the situations where the modules stop being loaded:
#   - a QTS firmware update wiped /etc/rcS.d/ or /etc/init.d/dvb-loader.sh
#   - the USB device was unplugged during boot
#   - module load order raced with USB enumeration
#
# What it does:
#   1. If the health path exists, do nothing — and log nothing, so a healthy
#      NAS does not spam the cron log.
#   2. If the installed artefacts are missing, re-run qnap-install.sh (it is
#      idempotent).
#   3. Re-run the loader directly, so the device comes back without a reboot.
#
# A second watchdog inside the TVH container restarts the container if the
# device is still missing after a few retries, covering the container side.
#
# Environment:
#   HEALTH_PATH  what "healthy" means (default /dev/dvb). The loader is
#                family-neutral, but the watchdog still has to decide whether
#                to act, and a directory that appears when the right modules
#                loaded is the cheapest such signal.
set -u

# Resolve through symlinks: installed as /etc/init.d/dvb-watchdog.sh, where a
# plain `dirname "$0"` would resolve PROJECT_DIR to /etc.
_realpath() {
    _p=$1
    while [ -L "$_p" ]; do
        _dir=$(dirname "$_p")
        _target=$(readlink "$_p")
        case "$_target" in
            /*) _p="$_target" ;;
            *)  _p="$_dir/$_target" ;;
        esac
    done
    printf '%s\n' "$_p"
}

PROJECT_DIR=$(cd "$(dirname "$(_realpath "$0")")/.." && pwd)

INSTALLER="${PROJECT_DIR}/scripts/qnap-install.sh"
LOADER="${PROJECT_DIR}/scripts/load-modules.sh"
LOG_DIR="${PROJECT_DIR}/logs"
LOG_FILE="${LOG_DIR}/dvb-watchdog.log"
HEALTH_PATH="${HEALTH_PATH:-/dev/dvb}"

mkdir -p "$LOG_DIR"
exec >> "$LOG_FILE" 2>&1

TS=$(date '+%Y-%m-%d %H:%M:%S')

# Fast path: nothing to do.
if [ -d "$HEALTH_PATH" ] && [ -n "$(ls "$HEALTH_PATH" 2>/dev/null)" ]; then
    exit 0
fi

echo "[$TS] watchdog: $HEALTH_PATH missing, attempting recovery"

# Re-install everything if a QTS firmware update wiped it.
if [ ! -f /etc/init.d/dvb-loader.sh ] || [ ! -L /etc/rcS.d/S98dvb-loader ] || \
   [ ! -f /etc/config/user_cmd/dvb-watchdog.cron ]; then
    echo "[$TS] watchdog: host-side artefacts missing, re-running installer"
    if [ -f "$INSTALLER" ]; then
        "$INSTALLER"
    else
        echo "[$TS] watchdog: ERROR installer missing at $INSTALLER"
        exit 1
    fi
fi

# Also restore the flash autorun.sh, the most durable piece. Only mount the
# flash partition if it is not already mounted, and only unmount it again if
# this script was the one that mounted it — unmounting someone else's mount
# would be a spectacular way for a watchdog to cause an outage.
BOOT_PD_FALLBACK="${BOOT_PD_FALLBACK:-/dev/sdc}"
MOUNTED_BY_US=0
if ! grep -q " /tmp/config " /proc/mounts 2>/dev/null; then
    HAL_BOOT_PD=$(/sbin/hal_app --get_boot_pd port_id=0 2>/dev/null || echo "$BOOT_PD_FALLBACK")
    if [ -b "${HAL_BOOT_PD}6" ] && mount "${HAL_BOOT_PD}6" /tmp/config 2>/dev/null; then
        MOUNTED_BY_US=1
    fi
fi

if grep -q " /tmp/config " /proc/mounts 2>/dev/null && [ ! -f /tmp/config/autorun.sh ]; then
    echo "[$TS] watchdog: /tmp/config/autorun.sh missing, re-running installer"
    if [ -f "$INSTALLER" ]; then
        [ "$MOUNTED_BY_US" -eq 1 ] && umount /tmp/config 2>/dev/null
        MOUNTED_BY_US=0
        "$INSTALLER"
    fi
fi

[ "$MOUNTED_BY_US" -eq 1 ] && umount /tmp/config 2>/dev/null

# Run the loader now to bring the device back without rebooting.
if [ ! -f "$LOADER" ]; then
    echo "[$TS] watchdog: ERROR loader missing at $LOADER"
    exit 1
fi

echo "[$TS] watchdog: invoking loader"
"$LOADER"
RC=$?

if [ "$RC" -eq 0 ]; then
    echo "[$TS] watchdog: recovery OK"
else
    echo "[$TS] watchdog: loader returned rc=$RC"
fi

exit "$RC"
