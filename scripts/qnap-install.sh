#!/bin/sh
# Install the module loader + watchdog so the built modules survive reboots
# and QTS firmware updates.
#
# Run this once on the NAS after copying the repo there, and re-run it after a
# QTS firmware update if /dev/dvb fails to come back.
#
# Idempotent. Two layers, and only two, because an actual reboot on 2026-10-08
# proved the other two this installer used to write cannot work on QTS:
#
#   1. boot:     /tmp/config/autorun.sh + Misc Autorun=TRUE. QTS mounts the boot
#                flash partition, runs that script, and unmounts it again. It
#                is the only hook that runs custom code at boot.
#   2. watchdog: one line in /etc/config/crontab, every 5 minutes.
#
# What it deliberately does NOT install, and why — all three were installed
# here before 2026-10-08 and the reboot showed none of them does anything:
#
#   /etc/init.d/*, /etc/rcS.d/*
#       `/` is a 400 MB tmpfs, so /etc is RAM and is wiped every boot. The
#       boot-time `ls` that once "verified" these only ever confirmed the files
#       existed, which they did — until the next restart.
#   /etc/config/user_cmd/*.cron
#       Not a cron mechanism. /sbin/user_cmd runs user *commands*; QTS builds
#       its crontab in /etc/init.d/crond.sh from /etc/config/crontab.
#   /etc/config/crontab.dynamic.*
#       That merge sits inside crond.sh's `[ -e /var/._viostor_ ]` branch, and
#       no such marker exists on a TS-x51, so the file would be read on no boot
#       at all. It is the right slot on a viostor QTS; it is a trap here.
#
# Stale copies of the retired artefacts are removed on every run (RETIRE below),
# including the two that live in the persistent /etc/config.
#
# Machine-specific values come from the environment, not from literals in this
# file (CLAUDE.md invariant 8):
#   BOOT_PD_FALLBACK  boot partition if QNAP's hal_app cannot report it
#                     (default /dev/sdc, the TS-x51 value)
set -u

# Resolve through symlinks: this may be invoked through one (a hand-wired
# startup entry, for instance), where a plain `dirname "$0"` would resolve
# PROJECT_DIR to /etc. busybox ash has no `readlink -f`, hence the walk.
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

LOADER_SRC="${PROJECT_DIR}/scripts/load-modules.sh"
WATCHDOG_SRC="${PROJECT_DIR}/scripts/dvb-watchdog.sh"

[ -f "$LOADER_SRC" ] || { echo "qnap-install: loader not found at $LOADER_SRC" >&2; exit 1; }
[ -f "$WATCHDOG_SRC" ] || { echo "qnap-install: watchdog not found at $WATCHDOG_SRC" >&2; exit 1; }
chmod 755 "$LOADER_SRC" "$WATCHDOG_SRC"

CRONTAB="/etc/config/crontab"
# Tagging the line the way QTS tags its own entries (see
# `/bin/...;#_QSC_:MalwareRemover:...` in $CRONTAB) makes it findable again on
# the next run, which is what lets a moved repo rewrite its own path.
CRON_MARKER="qnap-driver-builder:watchdog"

# The boot path this installer used to write. Dead on QTS — see the header.
RETIRED="/etc/init.d/dvb-loader.sh
/etc/init.d/dvb-watchdog.sh
/etc/rcS.d/S98dvb-loader
/etc/config/user_cmd/dvb-watchdog.cron"

# No log redirect on purpose: run by hand, the operator needs to see the
# next-steps block below; run by dvb-watchdog.sh, this output already lands in
# logs/dvb-watchdog.log because the watchdog redirected itself.
echo "[$(date '+%Y-%m-%d %H:%M:%S')] qnap-install start (project=$PROJECT_DIR)"

# ----------------------------------------------------------------------------
# Retire the artefacts earlier versions of this installer wrote
# ----------------------------------------------------------------------------
# Two of the four live in the persistent /etc/config, so unlike the /etc ones
# they would survive a reboot and keep advertising a boot path that does not
# exist. Removing them is idempotent, and absent is the normal case after the
# first run.
for stale in $RETIRED; do
    if [ -e "$stale" ] || [ -L "$stale" ]; then
        rm -f "$stale" && echo "[$(date '+%Y-%m-%d %H:%M:%S')] retired: $stale"
    fi
done

# ----------------------------------------------------------------------------
# Layer 1. The watchdog cron, in /etc/config/crontab
# ----------------------------------------------------------------------------
# /etc/config/crontab is the file QTS itself reads. /etc/init.d/crond.sh appends
# its own entries to it at boot and /usr/bin/crontab installs it into crond's
# spool; it lives on /dev/md9 through the /etc/config symlink, so it survives a
# reboot, which /tmp does not.
#
# Written whenever the content differs, not only when the file is absent: the
# line embeds an absolute path to the project, so a repo that has moved would
# otherwise leave the watchdog pointing at a path that no longer exists — the
# one failure mode that looks exactly like everything being fine.
CRON_LINE="*/5 * * * * ${WATCHDOG_SRC} >/dev/null 2>&1 #${CRON_MARKER}"

if [ ! -f "$CRONTAB" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: no $CRONTAB, watchdog cron not registered"
elif grep -qxF "$CRON_LINE" "$CRONTAB"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] already present: $CRON_LINE"
else
    # One backup, overwritten each time — this is QTS's live crontab, and the
    # sed below is the only thing here that edits a file in place.
    cp "$CRONTAB" "${CRONTAB}.bak-qnap-driver-builder" 2>/dev/null
    sed -i "/${CRON_MARKER}/d" "$CRONTAB"      # drop a stale line for this job
    printf '%s\n' "$CRON_LINE" >> "$CRONTAB"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] installed: $CRON_LINE"
fi

# Arm it now rather than at the next boot. crond reads a spool copy under /tmp,
# so editing the source file alone would not take effect until crond.sh
# regenerates it — which is exactly the "wrote the file, nothing runs" trap this
# installer was in.
if [ -x /usr/bin/crontab ] && [ -f "$CRONTAB" ]; then
    /usr/bin/crontab "$CRONTAB" && \
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] reloaded: crond spool from $CRONTAB"
fi

# ----------------------------------------------------------------------------
# Layer 2. QNAP-native flash autorun.sh
# ----------------------------------------------------------------------------
# /tmp/config/autorun.sh lives on the boot flash partition, which QTS mounts,
# runs, and unmounts during boot. It is the one hook that runs custom code at
# boot on this platform — everything under /etc is on the tmpfs. It is gated by
# the "Misc Autorun" config flag (Control Panel -> Hardware -> General), enabled
# here via setcfg so the install stays scriptable.
BOOT_PD_FALLBACK="${BOOT_PD_FALLBACK:-/dev/sdc}"
HAL_BOOT_PD=$(/sbin/hal_app --get_boot_pd port_id=0 2>/dev/null || echo "$BOOT_PD_FALLBACK")
CONFIG_PART="${HAL_BOOT_PD}6"
FLASH_MNT="/tmp/config"
AUTORUN_PATH="${FLASH_MNT}/autorun.sh"

if [ ! -b "$CONFIG_PART" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $CONFIG_PART is not a block device; skipping autorun.sh install"
else
    # QNAP's busybox ash lacks `mountpoint`, so check via /proc/mounts.
    MOUNTED_BY_US=0
    if ! grep -q " $FLASH_MNT " /proc/mounts 2>/dev/null; then
        if mount "$CONFIG_PART" "$FLASH_MNT" 2>/dev/null || \
           mount -t ext2 "$CONFIG_PART" "$FLASH_MNT" 2>/dev/null; then
            MOUNTED_BY_US=1
        fi
    fi

    if grep -q " $FLASH_MNT " /proc/mounts 2>/dev/null; then
        # The body delegates to the project script so all the logic stays in the
        # version-controlled repo, and this file stays a three-line stub.
        cat > "$AUTORUN_PATH" <<EOF
#!/bin/sh
# QNAP autorun.sh - generated by qnap-install.sh. Edits here are overwritten on
# the next install; edit scripts/load-modules.sh in the repo instead.
PROJECT_DIR="${PROJECT_DIR}"
if [ -x "\${PROJECT_DIR}/scripts/load-modules.sh" ]; then
    "\${PROJECT_DIR}/scripts/load-modules.sh"
else
    echo "autorun.sh: load-modules.sh not found at \${PROJECT_DIR}/scripts/" >&2
fi
exit 0
EOF
        chmod +x "$AUTORUN_PATH"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] installed: $AUTORUN_PATH"

        # Without this flag the script exists but is never invoked.
        CURRENT_AUTORUN=$(/sbin/getcfg Misc Autorun -d 0 2>/dev/null || echo "0")
        if [ "$CURRENT_AUTORUN" != "TRUE" ]; then
            /sbin/setcfg Misc Autorun TRUE
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] enabled: Misc Autorun=TRUE"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] already enabled: Misc Autorun"
        fi

        # Leave the flash partition as we found it — unmount only if this run
        # mounted it. QTS may already have it mounted, and a module installer
        # unmounting QTS's own config partition is a spectacular way to cause an
        # outage. Same guard as dvb-watchdog.sh.
        if [ "$MOUNTED_BY_US" -eq 1 ]; then
            umount "$FLASH_MNT" 2>/dev/null || \
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: failed to unmount $FLASH_MNT"
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: could not mount $CONFIG_PART; skipping autorun.sh"
    fi
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] qnap-install done"
echo
echo "Next steps:"
echo "  1. Test now:        ${LOADER_SRC}"
echo "  2. Verify:          ls -la /dev/dvb /dev/ttyUSB*"
echo "  3. Simulate crash:  ${WATCHDOG_SRC}"
echo "  4. Confirm the cron is live (expect one ${CRON_MARKER} line):"
echo "         crontab -l | grep ${CRON_MARKER}"
