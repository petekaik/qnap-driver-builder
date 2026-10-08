#!/bin/sh
# Load every driver family's modules on QNAP boot.
#
# QTS wipes /lib/modules/$(uname -r)/extra at every boot and has no autoload
# for out-of-tree modules, so this reinstalls and insmods them. The project
# root is auto-detected from this script's location.
#
# DRY_RUN=1 prints what it would do without touching /lib/modules.
PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
DRIVER_ROOT="$PROJECT_DIR"
. "$PROJECT_DIR/scripts/lib-drivers.sh"
MODULE_DIR="/lib/modules/$(uname -r)/extra"
LOG_FILE="${PROJECT_DIR}/logs/module-boot.log"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "${PROJECT_DIR}/logs"
exec 1>"$LOG_FILE" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting module load (project: $PROJECT_DIR)"

# QTS wipes /lib/modules/<kernel>/extra on reboot, so reinstall compiled modules.
# The DRY_RUN branch comes first on purpose: the dry run validates the declared
# load order, which is a property of the manifests, not of which .ko files this
# checkout happens to have. Requiring modules/ to be populated would make it
# useless on any machine that has not just built.
if [ "$DRY_RUN" = "1" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DRY_RUN: would install ${PROJECT_DIR}/modules/*.ko into ${MODULE_DIR} and run depmod -a"
else
    if [ ! -d "${PROJECT_DIR}/modules" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: compiled module backup not found at ${PROJECT_DIR}/modules"
        exit 1
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installing modules to ${MODULE_DIR}"
    mkdir -p "${MODULE_DIR}"
    cp -f "${PROJECT_DIR}/modules/"*.ko "${MODULE_DIR}/"
    depmod -a "$(uname -r)"
fi

# Ensure firmware is installed in /lib/firmware (QTS updates may wipe it).
for m in $(driver_list_manifests); do
    driver_source "$m" || continue
    for fw in $DRIVER_FIRMWARE; do
        if [ "$DRY_RUN" = "1" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] DRY_RUN: would sync firmware $fw [$DRIVER_NAME]"
        elif [ -f "${PROJECT_DIR}/firmware/$fw" ]; then
            if [ ! -e "/lib/firmware/$fw" ] || [ "${PROJECT_DIR}/firmware/$fw" -nt "/lib/firmware/$fw" ]; then
                cp -f "${PROJECT_DIR}/firmware/$fw" /lib/firmware/$fw
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installed / refreshed firmware: $fw [$DRIVER_NAME]"
            fi
        fi
    done
done

# Make sure USB devices have enumerated before loading drivers.
[ "$DRY_RUN" = "1" ] || sleep 3

# Load modules in each driver's declared order. Kernel module names use
# underscores while the compiled files use dashes, so map filename -> loaded
# name for the check. insmod, not modprobe: these are outside the depmod
# search path until the install above has run.
#
# The DRY_RUN branch is checked before the file-existence guard for the same
# reason as in the install block: it must print the whole declared order even
# when no .ko has been built yet, which is the only way to verify the order
# on a development machine.
for m in $(driver_list_manifests); do
    driver_source "$m" || continue
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Driver: $DRIVER_NAME ($DRIVER_DESCRIPTION)"
    for mod in $DRIVER_LOAD_ORDER; do
        mod_loaded=$(echo "$mod" | tr '-' '_')
        if [ "$DRY_RUN" = "1" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] DRY_RUN: would insmod ${MODULE_DIR}/${mod}.ko [$DRIVER_NAME]"
            continue
        fi
        if [ ! -f "${MODULE_DIR}/${mod}.ko" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Module not found: ${MODULE_DIR}/${mod}.ko [$DRIVER_NAME]"
            continue
        fi
        if lsmod | grep -q "^${mod_loaded} "; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Module already loaded: $mod"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Loading module: $mod"
            insmod "${MODULE_DIR}/${mod}.ko" 2>&1 || echo "WARN: failed to load $mod"
        fi
    done
done

[ "$DRY_RUN" = "1" ] || sleep 2

echo "[$(date '+%Y-%m-%d %H:%M:%S')] DVB adapters:"
ls -la /dev/dvb 2>&1 || echo "No /dev/dvb found"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Serial ports:"
ls -la /dev/ttyUSB* 2>&1 || echo "No /dev/ttyUSB* found"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done"
