#!/usr/bin/env bash
set -eo pipefail

. build_env.sh

export DRIVER_ROOT="$BASE_DIR"
. "$BASE_DIR/scripts/lib-drivers.sh"

# When set, resolve the driver manifests and print the build plan without
# downloading the GPL source or compiling anything. Seconds instead of an hour.
DRY_RUN="${DRY_RUN:-0}"

# Filename the GPL kernel archive is downloaded to, inside $SRC_DIR.
# Must be set here: it is used by the download branch below.
QNAP_ARCHIVE="GPL_QTS-${QNAP_VER}_Kernel.tar.gz"

# Merge every enabled driver's CONFIG entries, reject conflicts, and write them
# into the kernel .config in one pass — there is exactly one .config, shared by
# all drivers.
apply_config_patches() {
    local manifests="$1"
    local tokens

    echo "==> Merging CONFIG entries from driver manifests..."
    if ! tokens=$(driver_merge_configs $manifests); then
        echo "ERROR: driver manifests disagree about a CONFIG value (see above)" >&2
        return 1
    fi

    python3 "$BASE_DIR/apply_configs.py" "$KERNEL_DIR/.config" $tokens
}


# Print what a real build would do, without doing it.
print_build_plan() {
    local manifests="$1"
    local tokens

    echo "DRY_RUN: resolving only, nothing downloaded or built."
    echo
    echo "Enabled drivers ($DRIVERS):"
    for m in $manifests; do
        driver_source "$m"
        printf '    %-12s %s\n' "$DRIVER_NAME" "$DRIVER_DESCRIPTION"
    done

    echo
    echo "CONFIG entries (merged, conflict-checked):"
    if ! tokens=$(driver_merge_configs $manifests); then
        echo "ERROR: driver manifests disagree about a CONFIG value (see above)" >&2
        return 1
    fi
    printf '    %s\n' $tokens

    echo
    echo "Build commands:"
    for m in $manifests; do
        driver_source "$m"
        for dir in $DRIVER_DIRS; do
            printf '    make ARCH=x86_64 M=%s   # [%s]\n' "$dir" "$DRIVER_NAME"
        done
    done

    echo
    echo "Collect commands:"
    for m in $manifests; do
        driver_source "$m"
        for mod in $DRIVER_MODULES; do
            for root in $DRIVER_SEARCH_ROOTS; do
                printf '    find %s -name %s.ko -print -quit   # [%s]\n' "$root" "$mod" "$DRIVER_NAME"
            done
        done
    done
}


function build() {
    local manifests
    echo "==> Resolving driver manifests (DRIVERS='$DRIVERS')..."
    if ! manifests=$(driver_load_enabled $DRIVERS); then
        echo "ERROR: cannot resolve DRIVERS='$DRIVERS'" >&2
        return 1
    fi

    if [ "$DRY_RUN" = "1" ]; then
        print_build_plan "$manifests" || return 1
        return 0
    fi

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

    # Merge the enabled drivers' CONFIG entries into the kernel .config
    apply_config_patches "$manifests"

    echo "==> Preparing kernel build environment..."
    pushd "$KERNEL_DIR"

    # Build dependencies and version files
    make ARCH=x86_64 prepare 2>&1 | tail -5
    make ARCH=x86_64 modules_prepare 2>&1 | tail -5

    echo "==> Building kernel modules (this can take 30-90 minutes)..."
    local build_log="$BASE_DIR/logs/build.log"
    mkdir -p "$BASE_DIR/logs" /modules-out

    # One `make M=<dir>` per DRIVER_DIRS entry, in the order the manifests
    # declare — and they declare dependency order, because that is what makes
    # this work. `M=` declares a directory an *external* module build, and
    # modpost then resolves undefined symbols only against the symbols it
    # already knows: the ones QNAP itself built, plus whatever
    # KBUILD_EXTRA_SYMBOLS names. Modpost aborts the whole directory on the
    # first undefined symbol, so without the accumulation below em28xx (needs
    # tveeprom_hauppauge_analog from drivers/media/common) and si2168 and si2157
    # (need __regmap_init_i2c from drivers/base/regmap) are silently absent from
    # the output while their directories report success.
    #
    # Not one whole-tree `make modules`: that builds every =m module QNAP's
    # config enables, including drivers/target, whose own out-of-tree
    # qnap_se_dev_attr_dr code does not compile against this device config. A
    # failed prerequisite stops make from running the `modules` recipe — the
    # final modpost pass that emits every .ko — so one unrelated QNAP subtree
    # failing means *no* .ko at all, ours included. -k does not help: the
    # recipe is skipped, not the failing subtree.
    local extra_symvers=""
    for m in $manifests; do
        driver_source "$m" || return 1

        # Delete the .ko we are about to build, so a stale file left by an
        # earlier run cannot be collected as [OK] when this run failed to
        # produce it. [MISS] is worth nothing if it can be lied to.
        for mod in $DRIVER_MODULES; do
            for root in $DRIVER_SEARCH_ROOTS; do
                find "$root" -name "$mod.ko" -delete 2>/dev/null || true
            done
        done

        for dir in $DRIVER_DIRS; do
            if [ ! -d "$dir" ]; then
                echo "    [WARN] [$DRIVER_NAME] DRIVER_DIRS names $dir, which is not in this kernel tree"
                continue
            fi

            echo "    [$DRIVER_NAME] make M=$dir"
            if make ARCH=x86_64 M="$dir" KBUILD_EXTRA_SYMBOLS="$extra_symvers" \
                    -j"$(nproc)" modules 2>&1 | tee -a "$build_log" | tail -3; then
                :
            else
                echo "    [WARN] [$DRIVER_NAME] $dir failed to build; continuing"
            fi

            # Absolute: kbuild runs modpost from the tree root, not from here.
            # A directory with no =m objects writes no Module.symvers, and
            # naming a missing file would itself be a modpost error.
            if [ -f "$dir/Module.symvers" ]; then
                extra_symvers="$extra_symvers $KERNEL_DIR/$dir/Module.symvers"
            fi
        done
    done

    echo "==> Collecting modules..."
    for m in $manifests; do
        driver_source "$m" || return 1
        for mod in $DRIVER_MODULES; do
            mod_path=""
            for root in $DRIVER_SEARCH_ROOTS; do
                mod_path=$(find "$root" -name "$mod.ko" -print -quit 2>/dev/null || true)
                [ -n "$mod_path" ] && break
            done
            if [ -n "$mod_path" ]; then
                cp "$mod_path" /modules-out/
                echo "    [OK]   [$DRIVER_NAME] $mod ($(wc -c <"$mod_path" | tr -d ' ') bytes)"
            else
                echo "    [MISS] [$DRIVER_NAME] $mod — not produced; check DRIVER_DIRS and DRIVER_SEARCH_ROOTS"
            fi
        done
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