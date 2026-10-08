#!/usr/bin/env bash
TMP_BASE_DIR="$( cd "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
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

# Driver families to build, by manifest directory name under drivers/
DRIVERS=\\\"dvb usb-serial\\\"

# Device: TS-X51 series (TS-251/251+/451/651/851), Celeron J1900, x86_64
QNAP_DEVICE="TS-X51"
# Latest stable QTS 5.2.x with available GPL source
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