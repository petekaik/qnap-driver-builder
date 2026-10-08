#!/bin/sh
# Driver manifest loading, validation and config merging.
#
# Sourced by 2_build_modules.sh, scripts/load-modules.sh and
# scripts/verify-module-list.sh, so the manifest rules live in exactly one
# place. POSIX sh only — the NAS-side loader runs under busybox ash.
#
# Callers must set DRIVER_ROOT to the repository root before sourcing.
# Note: functions use _drv_/_dm_ prefixed variables rather than `local`,
# which is not POSIX.

: "${DRIVER_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
DRIVER_MANIFEST_DIR="$DRIVER_ROOT/drivers"

DRIVER_VARS="DRIVER_NAME DRIVER_DESCRIPTION DRIVER_CONFIGS DRIVER_DIRS \
DRIVER_MODULES DRIVER_LOAD_ORDER DRIVER_SEARCH_ROOTS DRIVER_FIRMWARE \
DRIVER_REQUIRES"

driver_fail() {
    echo "$*" >&2
    return 1
}

# Absolute paths of every manifest, sorted, for a deterministic order.
driver_list_manifests() {
    for _drv_m in "$DRIVER_MANIFEST_DIR"/*/manifest.sh; do
        [ -f "$_drv_m" ] || continue
        printf '%s\n' "$_drv_m"
    done
}

# driver_source <manifest-path> — clears the contract variables, then sources.
# Clearing first is what stops a manifest that omits a variable from silently
# inheriting the previously sourced manifest's value.
driver_source() {
    for _drv_v in $DRIVER_VARS; do
        unset "$_drv_v"
    done
    DRIVER_MANIFEST_PATH="$1"
    DRIVER_DIR_NAME=$(basename "$(dirname "$1")")
    # shellcheck disable=SC1090
    . "$1"
}

# Validate the currently sourced manifest. Returns non-zero with a message.
driver_validate() {
    for _drv_v in DRIVER_NAME DRIVER_DESCRIPTION DRIVER_CONFIGS DRIVER_DIRS \
                  DRIVER_MODULES DRIVER_LOAD_ORDER DRIVER_SEARCH_ROOTS; do
        eval "_drv_val=\${$_drv_v:-}"
        [ -n "$_drv_val" ] || {
            driver_fail "manifest '$DRIVER_DIR_NAME': $_drv_v is unset or empty"
            return 1
        }
    done
    [ "$DRIVER_NAME" = "$DRIVER_DIR_NAME" ] || {
        driver_fail "manifest '$DRIVER_DIR_NAME': DRIVER_NAME='$DRIVER_NAME' does not match its directory"
        return 1
    }
    for _drv_mod in $DRIVER_LOAD_ORDER; do
        case " $DRIVER_MODULES " in
            *" $_drv_mod "*) ;;
            *) driver_fail "$DRIVER_NAME: DRIVER_LOAD_ORDER entry '$_drv_mod' is not in DRIVER_MODULES"
               return 1 ;;
        esac
    done
    return 0
}

# driver_load_enabled <name>... — resolve names (and their DRIVER_REQUIRES,
# transitively) into manifest paths, requirer first. Each pass prints the names
# it was handed and queues their requires for the *next* pass, so a required
# driver is printed after the driver that requires it. Fails on an unknown name.
driver_load_enabled() {
    [ $# -gt 0 ] || { driver_fail "DRIVER is empty: set DRIVERS= in .env (see .env.example)"; return 1; }
    _drv_out=""
    _drv_todo="$*"
    _drv_depth=0
    while [ -n "$_drv_todo" ]; do
        _drv_depth=$((_drv_depth + 1))
        [ "$_drv_depth" -le 32 ] || { driver_fail "DRIVER_REQUIRES chain too deep or cyclic: $*"; return 1; }
        _drv_next=""
        for _drv_n in $_drv_todo; do
            _drv_p="$DRIVER_MANIFEST_DIR/$_drv_n/manifest.sh"
            if [ ! -f "$_drv_p" ]; then
                driver_fail "unknown driver '$_drv_n'. Available:$(driver_available_names)"
                return 1
            fi
            case "$_drv_out" in
                *"|$_drv_n|"*) continue ;;
            esac
            driver_source "$_drv_p" || return 1
            _drv_next="$_drv_next $DRIVER_REQUIRES"
            _drv_out="$_drv_out|$_drv_n|"
            printf '%s\n' "$_drv_p"
        done
        _drv_todo="$_drv_next"
    done
}

driver_available_names() {
    for _drv_m in "$DRIVER_MANIFEST_DIR"/*/manifest.sh; do
        [ -f "$_drv_m" ] || continue
        printf ' %s' "$(basename "$(dirname "$_drv_m")")"
    done
}

# driver_record_config <driver> <KEY=VALUE> — records a declaration and fails
# when a key already recorded by another driver carries a different value.
driver_record_config() {
    _drv_owner=$1
    _drv_key=${2%%=*}
    _drv_newval=${2#*=}
    eval "_drv_set=\${__drv_val_${_drv_key}+set}"
    if [ -z "$_drv_set" ]; then
        eval "__drv_val_${_drv_key}=\"\$_drv_newval\""
        eval "__drv_owner_${_drv_key}=\"\$_drv_owner\""
        return 0
    fi
    eval "_drv_oldval=\${__drv_val_${_drv_key}}"
    eval "_drv_oldowner=\${__drv_owner_${_drv_key}}"
    [ "$_drv_oldval" = "$_drv_newval" ] && return 0
    driver_fail "CONFIG conflict on $_drv_key: '$_drv_oldowner' declares $_drv_key=$_drv_oldval, '$_drv_owner' declares $_drv_key=$_drv_newval"
    return 1
}

# driver_merge_configs <manifest-path>... — validate each, detect conflicts,
# and print the merged KEY=VALUE tokens in driver order.
driver_merge_configs() {
    for _drv_p in "$@"; do
        driver_source "$_drv_p" || return 1
        driver_validate || return 1
        for _drv_tok in $DRIVER_CONFIGS; do
            driver_record_config "$DRIVER_NAME" "$_drv_tok" || return 1
            printf '%s\n' "$_drv_tok"
        done
    done
}

# Spec-named wrapper: same work, stdout discarded.
driver_check_config_conflicts() {
    driver_merge_configs "$@" >/dev/null
}
