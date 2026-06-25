#!/usr/bin/env bash
TMP_BASE_DIR="/build"
ENV_FILE="$TMP_BASE_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    echo "" > "$ENV_FILE"
fi

build_environment=$'
BASE_DIR="$TMP_BASE_DIR"

SRC_DIR="$BASE_DIR/src"
CONFIG_DIR="$BASE_DIR/config"
PATCH_DIR="$BASE_DIR/patches"
OUT_DIR="$BASE_DIR/out"

QNAP_DEVICE="TS-X51"
QNAP_VER="5.2.3.20250218"
QNAP_DIR="$SRC_DIR/GPL_QTS"

KERNEL_VER="5.10"
KERNEL_DIR="$QNAP_DIR/src/linux-$KERNEL_VER"
QNAP_KERNEL_CONFIG_FILE="$QNAP_DIR/kernel_cfg/$QNAP_DEVICE/linux-$KERNEL_VER-x86_64.config"'

while IFS='=' read -r key temp || [ -n "$key" ]; do
    case "$key" in
        '')
            continue
            ;;
    esac
    value=$(eval echo "$temp")
    eval export "$key='$value'"
    echo "$key=$value" >> .env
done <<< "$build_environment"
