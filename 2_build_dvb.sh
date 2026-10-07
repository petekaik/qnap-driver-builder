#!/usr/bin/env bash
set -eo pipefail

. build_env.sh

# Filename the GPL kernel archive is downloaded to, inside $SRC_DIR.
# Must be set here: it is used by the download branch below.
QNAP_ARCHIVE="GPL_QTS-${QNAP_VER}_Kernel.tar.gz"

# Turn on the DVB / USB-media CONFIG_* entries the modules need.
#
# apply_patches.py takes the config path as an absolute argument, so it does
# not care about the caller's cwd. The previous inline `scripts/config` version
# invoked a relative path from $SRC_DIR, so it always failed and fell through to
# a two-config sed that set them =m where =y is required (see CLAUDE.md).
apply_config_patches() {
    local cfg="$KERNEL_DIR/.config"

    echo "==> Applying .config patches to enable DVB/USB-media modules..."
    python3 "$BASE_DIR/apply_patches.py" "$cfg"
}


function build() {
    pushd "$SRC_DIR"

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
    pushd "$KERNEL_DIR"

    # Build dependencies and version files
    make ARCH=x86_64 prepare 2>&1 | tail -5
    make ARCH=x86_64 modules_prepare 2>&1 | tail -5

    # Modules the boot loader (scripts/load-dvb.sh) insmods, by basename.
    MODULES_LIST="
        em28xx
        em28xx-v4l2
        em28xx-dvb
        si2168
        si2157
        dvb-core
        dvb-usb
        v4l2-common
        tveeprom
        tuner
        videobuf2-common
        videobuf2-memops
        videobuf2-v4l2
        videobuf2-vmalloc
    "

    # Subtrees that produce them. `make M=<dir>` builds the whole directory
    # (including its subdirectories), so this replaces the old one-make-per-.ko
    # loop. Directories absent from this kernel tree are skipped, and a module
    # is collected by name rather than by hard-coded path on purpose: tveeprom
    # and tuner have moved between kernel releases, and the collection step
    # finds each .ko wherever it landed.
    MODULE_DIRS="
        drivers/media/usb/em28xx
        drivers/media/dvb-frontends
        drivers/media/tuners
        drivers/media/dvb-core
        drivers/media/usb/dvb-usb
        drivers/media/v4l2-core
        drivers/media/common
        drivers/media/i2c
    "

    echo "==> Building kernel modules (this can take 30-90 minutes)..."
    local build_log="$BASE_DIR/logs/build.log"
    mkdir -p "$BASE_DIR/logs" /modules-out

    for media_dir in $MODULE_DIRS; do
        if [ ! -d "$media_dir" ]; then
            echo "    [SKIP] $media_dir (not in this kernel tree)"
            continue
        fi
        echo "    -> building $media_dir"
        if make ARCH=x86_64 M="$media_dir" -j"$(nproc)" 2>&1 | tee -a "$build_log" | tail -3; then
            :
        else
            echo "       [WARN] $media_dir failed to build"
        fi
    done

    echo "==> Collecting modules..."
    for mod in $MODULES_LIST; do
        mod_path=$(find drivers/media -name "$mod.ko" -print -quit 2>/dev/null || true)
        if [ -n "$mod_path" ]; then
            cp "$mod_path" /modules-out/
            echo "    [OK]   $mod ($(wc -c <"$mod_path" | tr -d ' ') bytes)"
        else
            echo "    [MISS] $mod — not produced; add its subtree to MODULE_DIRS"
        fi
    done

    popd
    popd

    echo "==> Build complete. Modules in /modules-out/:"
    ls -la /modules-out/
}


function clean() {
    rm -rf "$QNAP_DIR"
    rm -rf /modules-out/*
}


entry_point "$@"