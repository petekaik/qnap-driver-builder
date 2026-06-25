#!/bin/sh
# Load custom DVB modules on QNAP boot and ensure firmware files are present.
# The project root is auto-detected from this script's location, so it works
# regardless of where the repository is cloned.

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
MODULE_DIR="/lib/modules/$(uname -r)/extra"
LOG_FILE="${PROJECT_DIR}/logs/dvb-boot.log"

mkdir -p "${PROJECT_DIR}/logs"
exec 1>"$LOG_FILE" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting DVB module load (project: $PROJECT_DIR)"

# Ensure firmware is installed in /lib/firmware (QTS updates may wipe it)
for fw in dvb-demod-si2168-b40-01.fw dvb-demod-si2168-d60-01.fw dvb-demod-si2168-02.fw; do
    if [ -f "${PROJECT_DIR}/firmware/$fw" ]; then
        if [ ! -e "/lib/firmware/$fw" ] || [ "${PROJECT_DIR}/firmware/$fw" -nt "/lib/firmware/$fw" ]; then
            cp "${PROJECT_DIR}/firmware/$fw" /lib/firmware/$fw
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installed / refreshed firmware: $fw"
        fi
    fi
done

# Make sure the USB stick is enumerated before loading drivers
sleep 3

# Load modules in dependency order. Kernel module names use underscores while
# the compiled files use dashes, so map filename -> loaded name for the check.
for mod in videobuf2-common videobuf2-memops videobuf2-v4l2 videobuf2-vmalloc tuner tveeprom si2157 si2168 dvb-usb em28xx em28xx-dvb; do
    mod_loaded=$(echo "$mod" | tr '-' '_')
    if [ -f "${MODULE_DIR}/${mod}.ko" ]; then
        if lsmod | grep -q "^${mod_loaded} "; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Module already loaded: $mod"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Loading module: $mod"
            insmod "${MODULE_DIR}/${mod}.ko" 2>&1 || echo "WARN: failed to load $mod"
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Module not found: ${MODULE_DIR}/${mod}.ko"
    fi
done

sleep 2

echo "[$(date '+%Y-%m-%d %H:%M:%S')] DVB adapters:"
ls -la /dev/dvb 2>&1 || echo "No /dev/dvb found"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done"
