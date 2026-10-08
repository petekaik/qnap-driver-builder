#!/bin/sh
# Install the module loader + watchdog so the built modules survive reboots
# and QTS firmware updates.
#
# Run this once on the NAS after copying the repo there, and re-run it after a
# QTS firmware update if /dev/dvb fails to come back.
#
# Idempotent. Three layers, least durable first, so a QTS update has to destroy
# all three to stop the modules loading:
#   1. boot ordering:  /etc/init.d/dvb-loader.sh -> scripts/load-modules.sh,
#                      and /etc/rcS.d/S98dvb-loader -> that, so it runs at boot
#   2. watchdog:       /etc/config/user_cmd/dvb-watchdog.cron, every 5 minutes
#   3. flash autorun:  /tmp/config/autorun.sh + Misc Autorun=TRUE, on the flash
#                      partition, which QTS firmware updates do not wipe
#
# The symlinks point into the project rather than copying, so editing the repo
# takes effect on the next boot without re-running this installer.
#
# Machine-specific values come from the environment, not from literals in this
# file (CLAUDE.md invariant 8):
#   BOOT_PD_FALLBACK  boot partition if QNAP's hal_app cannot report it
#                     (default /dev/sdc, the TS-x51 value)
set -u

# Resolve through symlinks: this is installed as an /etc symlink, where a plain
# `dirname "$0"` would resolve PROJECT_DIR to /etc. busybox ash has no
# `readlink -f`, hence the walk.
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

# The init/rcS names say "dvb" for history: that is what is already installed on
# the NAS, and renaming a live boot path to gain tidiness risks a dangling
# symlink and a silent loss of load-on-boot. The loader they point at is
# family-neutral and reads the manifests.
INIT_LOADER="/etc/init.d/dvb-loader.sh"
INIT_WATCHDOG="/etc/init.d/dvb-watchdog.sh"
RC_LINK="/etc/rcS.d/S98dvb-loader"
USER_CMD_CRON="/etc/config/user_cmd/dvb-watchdog.cron"

# No log redirect on purpose: run by hand, the operator needs to see the
# next-steps block below; run by dvb-watchdog.sh, this output already lands in
# logs/dvb-watchdog.log because the watchdog redirected itself.
echo "[$(date '+%Y-%m-%d %H:%M:%S')] qnap-install start (project=$PROJECT_DIR)"

# ----------------------------------------------------------------------------
# Layer 1a. /etc/init.d symlinks
# ----------------------------------------------------------------------------
# /etc/init.d survives normal reboots but may be wiped by a QTS firmware
# update — dvb-watchdog.sh restores it.
install_symlink() {
    _src=$1
    _dest=$2
    if [ ! -f "$_src" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: not found at $_src"
        return 1
    fi
    chmod 755 "$_src"
    # Replace a real file, or a symlink pointing somewhere else (the project may
    # have moved since the last install).
    if [ -e "$_dest" ] && [ ! -L "$_dest" ]; then
        rm -f "$_dest"
    fi
    if [ -L "$_dest" ] && [ "$(readlink "$_dest")" = "$_src" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] already installed: $_dest"
        return 0
    fi
    rm -f "$_dest"
    ln -s "$_src" "$_dest" && echo "[$(date '+%Y-%m-%d %H:%M:%S')] installed: $_dest -> $_src"
}

install_symlink "$LOADER_SRC" "$INIT_LOADER" || exit 1
install_symlink "$WATCHDOG_SRC" "$INIT_WATCHDOG" || exit 1

# ----------------------------------------------------------------------------
# Layer 1b. /etc/rcS.d/S98dvb-loader
# ----------------------------------------------------------------------------
# QNAP's own services start at S99, so S98 places us before them.
if [ -e "$RC_LINK" ] || [ -L "$RC_LINK" ]; then
    rm -f "$RC_LINK"
fi
ln -s "$INIT_LOADER" "$RC_LINK"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] installed: $RC_LINK -> $INIT_LOADER"

# ----------------------------------------------------------------------------
# Layer 2. Cron registration via user_cmd
# ----------------------------------------------------------------------------
# QNAP's own `0 0 * * * /sbin/user_cmd -C` runs every *.cron file in
# /etc/config/user_cmd/, so dropping a file there avoids editing
# /etc/config/crontab directly (which QTS firmware updates wipe).
#
# Rewritten whenever the content differs, not only when the file is absent: the
# cron line embeds an absolute path to the project, so a repo that has moved
# would otherwise leave the watchdog pointing at a path that no longer exists —
# the one failure mode that looks exactly like everything being fine.
USER_CMD_CRON_LINE="*/5 * * * * ${WATCHDOG_SRC} >/dev/null 2>&1"
USER_CMD_DIR="$(dirname "$USER_CMD_CRON")"

if [ -d "$USER_CMD_DIR" ] || mkdir -p "$USER_CMD_DIR" 2>/dev/null; then
    if grep -qxF "$USER_CMD_CRON_LINE" "$USER_CMD_CRON" 2>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] already present: $USER_CMD_CRON"
    else
        printf '%s\n' "$USER_CMD_CRON_LINE" > "$USER_CMD_CRON"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] installed: $USER_CMD_CRON"
    fi
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: could not create $USER_CMD_DIR, watchdog cron not registered"
fi

# ----------------------------------------------------------------------------
# Layer 3. QNAP-native flash autorun.sh
# ----------------------------------------------------------------------------
# /tmp/config/autorun.sh lives on the flash partition and survives QTS firmware
# updates, which /etc/rcS.d symlinks do not. It is gated by the "Misc Autorun"
# config flag (Control Panel -> Hardware -> General), enabled here via setcfg so
# the install stays scriptable.
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
