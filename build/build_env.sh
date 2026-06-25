#!/usr/bin/env bash
# Build environment helpers for QNAP DVB module build
# Simplified: no pushd/popd, just cd pairs

if [ "$BUILD_ENV_LOADED" = "true" ]; then
    return 0
fi

# Disable bash builtins that may conflict
enable -n pushd 2>/dev/null || true
enable -n popd 2>/dev/null || true

set -e

if [ ! -f ".env" ]; then
    echo "Please run 0_prepare.sh first!" >&2
    return 1
fi
. .env

_BUILD_OLD_DIR=""

function _enter() {
    _BUILD_OLD_DIR="$(pwd)"
    cd "$BASE_DIR" || return 1
    export BUILD_ENV_ENTERED="true"
}

function _leave() {
    rm -rf "${TMP_DIR:-}" 2>/dev/null || true
    if [ "$BUILD_ENV_ENTERED" = "true" ]; then
        cd "$_BUILD_OLD_DIR" || true
        unset BUILD_ENV_ENTERED
    fi
}

function _build() {
    _enter
    if declare -f -F "build" > /dev/null; then
        build
    fi
    if declare -f -F "collect_artifacts" > /dev/null; then
        collect_artifacts
    fi
    _leave
}

function _clean() {
    _enter
    if declare -f -F "clean" > /dev/null; then
        clean
    fi
    _leave
}

function apply_patches() {
    for patch_file in "$1"/*.patch; do
        [ -f "$patch_file" ] || break
        echo "Applying patch $patch_file"
        if grep -q -- "--git" "$patch_file"; then
            out=$(patch -N -d "$2" -p1 < "$patch_file") || echo "${out}" | grep "Skipping patch" -q || (echo "$out" && false)
        else
            out=$(patch -N -d "$2" -p0 < "$patch_file") || echo "${out}" | grep "Skipping patch" -q || (echo "$out" && false)
        fi
    done
}

function entry_point() {
    case "${1:-build}" in
        "build")
            _build
            ;;
        "clean")
            _clean
            ;;
        *)
            _build
            ;;
    esac
}

function exit() {
    _leave
    command exit "$@"
}

BUILD_ENV_LOADED="true"
