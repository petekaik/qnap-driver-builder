#!/bin/sh
# Assert that every module the boot loader loads is one the builder builds.
#
# The two lists drift silently: a module scripts/load-dvb.sh insmods but
# MODULES_LIST never produces only shows up as "Module not found" on the NAS,
# after a reboot, with no DVB adapters. Run this after editing either list.
#
#   scripts/verify-module-list.sh
#
# Exits non-zero and names the offenders on mismatch.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

loaded=$(sed -n 's/^for mod in \(.*\); do$/\1/p' "$here/load-dvb.sh")
[ -n "$loaded" ] || { echo "FAIL: could not parse the module list from load-dvb.sh" >&2; exit 1; }

built=$(sed -n '/^    MODULES_LIST="/,/^    "$/p' "$root/2_build_dvb.sh")
[ -n "$built" ] || { echo "FAIL: could not parse MODULES_LIST from 2_build_dvb.sh" >&2; exit 1; }

missing=""
for mod in $loaded; do
    printf '%s\n' "$built" | grep -qx "        $mod" || missing="$missing $mod"
done

if [ -n "$missing" ]; then
    echo "FAIL: loaded by scripts/load-dvb.sh but not in MODULES_LIST (2_build_dvb.sh):$missing" >&2
    exit 1
fi

echo "OK: all $(printf '%s\n' $loaded | wc -l | tr -d ' ') modules loaded by load-dvb.sh are in MODULES_LIST"
