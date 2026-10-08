#!/bin/sh
# Compatibility shim. The loader was renamed to load-modules.sh when the
# builder became driver-agnostic. A QTS startup cron entry or Control Panel
# "Startup" task still pointing at this path would otherwise silently stop
# loading the modules — QTS wipes /lib/modules/<ver>/extra at every boot, so
# the symptom would be a missing /dev/dvb after a reboot, with nothing to
# explain it. Safe to delete once every NAS has been repointed.
exec "$(cd "$(dirname "$0")" && pwd)/load-modules.sh" "$@"
