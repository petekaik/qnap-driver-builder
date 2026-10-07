#!/usr/bin/env bash

##################################################
# Check if the build environment is already loaded
##################################################
if [ "$BUILD_ENV_LOADED" = "true" ]; then
    return 0
fi

set -e

if [ ! -f ".env" ]; then
    echo "Please run 0_prepare.sh first!" >&2
    return 1
fi
. .env

function _enter() {
    pushd "$BASE_DIR"
    export BUILD_ENV_ENTERED="true"
}

function _leave() {
    rm -rf "$TMP_DIR"
    if [ "$BUILD_ENV_ENTERED" = "true" ]; then
        popd
        unset BUILD_ENV_ENTERED
    fi
}

function _build() {
    _enter
    declare -f -F "build" > /dev/null && build
    declare -f -F "collect_artifacts" > /dev/null && collect_artifacts
    _leave
}

function _clean() {
    _enter
    declare -f -F "clean" > /dev/null && clean
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

function pushd() {
    command pushd "$@" > /dev/null
}
function popd() {
    command popd "$@" > /dev/null
}

function entry_point() {
    case "$1" in
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