#!/bin/sh
# Assert that the driver manifests are well formed, and that everything which
# consumes them agrees. Previously this regex-parsed the loader's `for mod in`
# line, so a reformat silently defeated it; now both sides are data.
#
#   scripts/verify-module-list.sh
#
# Static only: no Docker, no kernel tree. Exits non-zero and names offenders.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
DRIVER_ROOT="$root"
export DRIVER_ROOT
. "$here/lib-drivers.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

manifest_count=0

for m in $(driver_list_manifests); do
    driver_source "$m" || fail "cannot source $m"
    driver_validate || fail "invalid manifest: $m"

    # A manifest must parse as POSIX sh — the loader runs it under busybox ash.
    sh -n "$m" || fail "not valid POSIX sh: $m"
    bash -n "$m" || fail "not valid bash: $m"
    # sh -n is NOT enough on its own: where /bin/sh *is* bash (macOS, and this
    # project's dev machines) an array passes it happily, and the failure only
    # appears at boot on the NAS. Grep for the constructs that break there.
    if grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\(|[[:space:]]\[\[|^[[:space:]]*local[[:space:]]' "$m"; then
        fail "$m uses a bashism (array, [[ ]], or local) that busybox ash will reject"
    fi

    dup=$(printf '%s\n' "$DRIVER_MODULES" | sort | uniq -d | tr '\n' ' ')
    [ -z "$dup" ] || fail "$DRIVER_NAME: duplicate DRIVER_MODULES entries: $dup"

    manifest_count=$((manifest_count + 1))
done

[ "$manifest_count" -gt 0 ] || fail "no manifests found under $DRIVER_MANIFEST_DIR"

# Every driver named in .env.example must exist, so a typo'd plugin name fails
# here rather than after a 90-minute build.
env_drivers=$(sed -n 's/^DRIVERS=//p' "$root/.env.example" | head -1 | tr -d '"')
[ -n "$env_drivers" ] || fail ".env.example sets no DRIVERS="
for d in $env_drivers; do
    [ -d "$DRIVER_MANIFEST_DIR/$d" ] || fail ".env.example DRIVERS names '$d', which has no manifest"
done

# No two enabled drivers may disagree about a CONFIG_* value.
enabled=$(driver_load_enabled $env_drivers) || fail "cannot resolve DRIVERS='$env_drivers'"
driver_check_config_conflicts $enabled || fail "driver manifests declare conflicting CONFIG values (above)"

# Warning: modules built and installed but never insmod-ed. Not a failure —
# some are built-in dependencies — but it is the difference between "the .ko
# is there" and "the driver is running".
for m in $enabled; do
    driver_source "$m"
    for mod in $DRIVER_MODULES; do
        case " $DRIVER_LOAD_ORDER " in
            *" $mod "*) ;;
            *) echo "WARN: $DRIVER_NAME builds '$mod' but never loads it (absent from DRIVER_LOAD_ORDER)" ;;
        esac
    done
done

echo "OK: $manifest_count manifest(s) valid; DRIVERS='$env_drivers'; load order agrees with the module lists"
