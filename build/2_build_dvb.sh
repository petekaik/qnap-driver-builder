#!/usr/bin/env bash
set -e

. build_env.sh
QNAP_ARCHIVE="GPL_QTS-${QNAP_VER}_Kernel.tar.gz"

# Apply patches that enable DVB/USB-media support in kernel config
# These use scripts/config which modifies .config without re-running menuconfig
apply_config_patches() {
    local cfg="$KERNEL_DIR/.config"

    echo "==> Applying .config patches to enable DVB/USB-media modules..."

    if [ -f /build/apply_patches.py ]; then
        python3 /build/apply_patches.py "$cfg"
    else
        echo "WARN: apply_patches.py not found, skipping"
    fi
}


function build() {
    cd "$SRC_DIR"

    if [[ ! -d "$QNAP_DIR" ]]; then
        echo "==> Downloading QNAP GPL kernel source..."
        echo "    QNAP_VER=$QNAP_VER"
        echo "    QNAP_DEVICE=$QNAP_DEVICE"

        single_tar_url="https://sourceforge.net/projects/qosgpl/files/QNAP%20NAS%20GPL%20Source/QTS%20${QNAP_VER:0:5}/GPL_QTS-${QNAP_VER}_Kernel.tar.gz"

        ret_code=$(curl -sLIk -o /dev/null -w "%{http_code}" --max-time 60 "$single_tar_url")
        echo "    URL check: $single_tar_url -> HTTP $ret_code"

        if [ "$ret_code" -eq "200" ]; then
            echo "==> Downloading GPL_QTS-${QNAP_VER}_Kernel.tar.gz..."
            curl -Lk --max-time 1800 "$single_tar_url" -o "$QNAP_ARCHIVE" 2>&1 | tail -3
            echo "==> Extracting..."
            tar -zxf "$QNAP_ARCHIVE"
            rm "$QNAP_ARCHIVE"
        else
            echo "==> Single tar not available, trying split files..."
            file_counter=0
            while true; do
                split_tar_url="https://sourceforge.net/projects/qosgpl/files/QNAP%20NAS%20GPL%20Source/QTS%20${QNAP_VER:0:5}/QTS_Kernel_${QNAP_VER}.${file_counter}.tar.gz"
                ret_code=$(curl -sLIk -o /dev/null -w "%{http_code}" --max-time 30 "$split_tar_url")
                [ "$ret_code" -eq "200" ] || break
                curl -Lk --max-time 1800 "$split_tar_url" -o "${QNAP_ARCHIVE}.${file_counter}"
                file_counter=$((file_counter + 1))
            done
            cat "${QNAP_ARCHIVE}."* | tar -zxf -
            rm "${QNAP_ARCHIVE}."*
        fi
    fi

    # copy the kernel config to the kernel directory
    if [ ! -f "$QNAP_KERNEL_CONFIG_FILE" ]; then
        echo "ERROR: Kernel config file not found: $QNAP_KERNEL_CONFIG_FILE"
        echo "Available configs:"
        find "$QNAP_DIR/kernel_cfg" -type f 2>/dev/null | head -20
        return 1
    fi

    cp "$QNAP_KERNEL_CONFIG_FILE" "$KERNEL_DIR/.config"
    echo "==> Copied kernel config from $QNAP_KERNEL_CONFIG_FILE"

    # Apply config patches to enable DVB/USB-media modules
    apply_config_patches

    echo "==> Preparing kernel build environment..."
    cd "$KERNEL_DIR"

    # Build dependencies and version files
    make ARCH=x86_64 prepare 2>&1 | tail -5
    make ARCH=x86_64 modules_prepare 2>&1 | tail -5

    # Get list of Media/USB/DVB modules to compile
    MODULES_LIST="
        drivers/media/usb/em28xx/em28xx.ko
        drivers/media/usb/em28xx/em28xx-v4l2.ko
        drivers/media/usb/em28xx/em28xx-dvb.ko
        drivers/media/dvb-frontends/si2168.ko
        drivers/media/tuners/si2157.ko
        drivers/media/dvb-core/dvb-core.ko
        drivers/media/usb/dvb-usb/dvb-usb.ko
        drivers/media/v4l2-core/v4l2-common.ko
    "

    echo "==> Building kernel modules (this can take 30-90 minutes)..."
    local build_log="$BASE_DIR/logs/build.log"
    mkdir -p "$BASE_DIR/logs"

    for mod_path in $MODULES_LIST; do
        mod_name=$(basename "$mod_path" .ko)
        echo "    -> $mod_name"

        if make ARCH=x86_64 M=$(dirname "$mod_path") -j$(nproc) 2>&1 | tail -5; then
            if [ -f "$mod_path" ]; then
                cp "$mod_path" /modules-out/
                echo "       [OK] $(ls -la $mod_path | awk '{print $5}') bytes"
            fi
        else
            echo "       [WARN] $mod_name build failed, will try without"
        fi
    done

    cd ..
    cd ..

    echo "==> Build complete. Modules in /modules-out/:"
    ls -la /modules-out/
}


function clean() {
    rm -rf "$QNAP_DIR"
    rm -rf /modules-out/*
}


entry_point "$@"

