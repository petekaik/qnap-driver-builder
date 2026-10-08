# Modular driver builder — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `qnap-driver-builder` from a DVB-only module builder into a manifest-driven one where a driver family is a single `drivers/<name>/manifest.sh`, and add USB-serial as the second family.

**Architecture:** Each driver family ships one POSIX-sh manifest file declaring the `CONFIG_*` entries it owns, the kernel subtrees to build, the `.ko` names to collect, the `insmod` order, and any firmware. A small shared library (`scripts/lib-drivers.sh`) loads and validates those manifests, and the builder, the boot loader and the verifier all consume it — so the three cannot drift apart. `apply_configs.py` becomes a dumb writer of `KEY=VALUE` tokens, and all driver-specific knowledge moves into manifests.

**Tech Stack:** POSIX `sh` (manifests and the NAS-side loader run under busybox ash), Bash (builder, `set -eo pipefail`), Python 3 (the config writer), Docker for the kernel build.

**Spec:** `docs/03-modular-driver-builder-design.md`

## Global Constraints

- **Manifests are POSIX `sh`**, sourced by the boot loader under busybox `ash`: plain `VAR="…"` assignments only — **no arrays, no bashisms**. Every manifest must pass `sh -n` and `bash -n`.
- **`CONFIG_*` values are carried verbatim.** The `=y` / `=m` split is load-bearing (design invariant 4): a dependency set to `=m` that is never built breaks dependents with unresolved `Module.symvers` symbols. Never "tidy" a value.
- **`DRIVER_LOAD_ORDER` ⊆ `DRIVER_MODULES`**, per driver (design invariant 5). Order is **declared, not derived** (invariant 7).
- **DVB behaviour must not change.** After the restructure the DVB family must still declare exactly: 31 `CONFIG_*` entries, 8 dirs, 14 modules, 11 load-order entries, 3 firmware files.
- **`.env` paths are container-absolute** (`/build/…`) and `.env` must never be added to `.dockerignore` (invariants 2 and 3). `.env` is gitignored; `.env.example` carries anonymised placeholders only (invariant 8).
- **Nothing sensitive is publishable.** Run `sh scripts/check-secrets.sh` before every commit. The repo has it installed as a pre-commit hook — **never bypass it with `git commit --no-verify`**.
- **Syntax-check before every commit:** `bash -n` on bash, `sh -n` on POSIX scripts and manifests, `python3 -m py_compile` on Python.
- Tests are plain `sh` scripts in `scripts/`, no framework. Add asserts to the existing check rather than introducing a suite.
- Commits end with `Co-Authored-By: Claude Code <noreply@anthropic.com>`.

## Review Focus

These are the input classes and failure modes the spec implies but whose tests would otherwise be missing. Each is pinned by a test in the task named.

| # | Input / condition | Expected behaviour | Pinned by |
|---|---|---|---|
| 1 | A name in `DRIVERS=` with no manifest directory | Hard failure naming the available drivers — never a silent build of fewer modules | Task 3, step 11 |
| 2 | A manifest that omits a variable the previous manifest set | The omitted variable must be **empty**, not inherited from the previously sourced manifest | Task 1, step 12 |
| 3 | `DRIVERS=` unset or empty in `.env` | Clear failure, not a build that produces zero modules | Task 3, step 12 |
| 4 | Two drivers declaring one `CONFIG_*` key with different values | Hard failure naming both drivers and the key | Task 1, step 14 |
| 5 | A crontab still pointing at `scripts/load-dvb.sh` after the rename | Keeps working — the old path survives as a shim that execs the new loader | Task 4, step 9 |
| 6 | A `=y` config entry listed in `DRIVER_MODULES` (cannot emit a `.ko`) | Reported as `[MISS]` at collect time, and as a warning by the verifier; never treated as success | Task 1, step 10 (the warning); the `[MISS]` itself needs a real build — see *After the plan* |
| 7 | A module collected but absent from `DRIVER_LOAD_ORDER` | Warning from the verifier, naming the module — installed but never loaded | Task 1, step 10 |

## Deviations from the spec, decided while planning

Recorded here so a reviewer can reject them explicitly rather than discover them:

1. **Spec's `driver_all_modules_of` / `driver_load_order_of` / `driver_firmware_of` accessors are not written as functions.** After `driver_source`, the manifest's variables *are* the accessors. Wrapping them adds indirection with no consumer.
2. **`driver_merge_configs` both checks and emits.** The spec names a separate `driver_check_config_conflicts`; it is kept as a two-line wrapper that discards stdout, so both spec names exist and one recorder implementation does the work.
3. **`driver_load_enabled` prints resolved manifest paths** in dependency order (requires first) rather than only sourcing them — that is how the builder gets its per-driver iteration without a second call.
4. **A `DRY_RUN=1` mode is added to both the builder and the loader.** Without it the build wiring and the boot loader have no test that runs in seconds, and the repo has no Docker-in-CI. It doubles as "what would this build?". Both are ~10 lines.
5. **The plan document is `docs/04-modular-driver-builder-plan.md` and the new guide is `docs/05-adding-a-driver.md`**, following the repo's `docs/NN-name.md` convention over the skill default. Task 5 fixes the two references in the spec (which said `docs/04-adding-a-driver.md`).
6. **The spec's `driver_extra_build()` / `driver_extra_collect()` escape hatch is dropped.** It has no user, and as specified it is unsound: `driver_source` clears variables but not functions, so a hook defined by one manifest would still be defined — and get called — while the next driver is being built. Making it correct needs a per-driver `unset -f`, which is more machinery than the hatch saves. If a driver family ever genuinely needs custom build work, add the hatch then, with the leak fixed. Task 5's guide therefore does *not* document it. The spec should be updated to say so.
7. **Verifier assert 5 is strengthened beyond the spec.** The spec says passing `sh -n` and `bash -n` "catches an accidental bashism". It does not, where `/bin/sh` is bash — which it is on this project's macOS dev machines, verified: an array returns exit 0 from `sh -n` here. The verifier therefore also greps each manifest for arrays, `[[`, and `local`. Task 5 corrects the spec's assert-5 wording, because the spec's stated rationale is false and would invite the check to be removed as redundant.

---

## File structure

| File | Responsibility |
|---|---|
| `drivers/dvb/manifest.sh` | Create. The DVB family's config entries, dirs, modules, load order, firmware. |
| `drivers/usb-serial/manifest.sh` | Create. The USB-serial family's equivalent. |
| `scripts/lib-drivers.sh` | Create. Manifest discovery, sourcing, validation, `DRIVER_REQUIRES` resolution, config merge and conflict detection. The only place manifest rules live. |
| `scripts/verify-module-list.sh` | Rewrite. Manifest-aware asserts 1–8; no longer regex-parses the loader. |
| `apply_configs.py` | Create (replaces `apply_patches.py`). Writes `KEY=VALUE` tokens into a `.config`; knows nothing about any driver. |
| `2_build_modules.sh` | Rename + modify. Resolves drivers, patches once, builds declared dirs, collects by declared roots. |
| `scripts/load-modules.sh` | Rename + modify. Installs, syncs firmware, `insmod`s in declared order, per driver. |
| `scripts/load-dvb.sh` | Keep as a shim that execs the new loader. |
| `.env.example`, `0_prepare.sh`, `docker_entrypoint.sh`, `Dockerfile` | Add `DRIVERS=`; point at the renamed scripts. |
| `docs/01`, `docs/02`, `docs/05`, `README.md`, `CLAUDE.md`, `docs/03` | Docs follow the code. |

---

## Task 1: Manifests, the driver library, and a manifest-aware verifier

The contract and its enforcement. After this task a driver family exists as data, and `scripts/verify-module-list.sh` fails when that data is malformed or inconsistent. Nothing consumes it yet.

**Files:**
- Create: `drivers/dvb/manifest.sh`
- Create: `drivers/usb-serial/manifest.sh`
- Create: `scripts/lib-drivers.sh`
- Rewrite: `scripts/verify-module-list.sh`
- Modify: `.env.example`

**Interfaces:**
- Consumes: nothing.
- Produces: `driver_list_manifests`, `driver_source <path>`, `driver_validate`, `driver_load_enabled <name>…`, `driver_merge_configs <path>…`, `driver_check_config_conflicts <path>…`, `driver_record_config <driver> <KEY=VALUE>`, `driver_fail <msg>`. After `driver_source`, the variables `DRIVER_NAME`, `DRIVER_DESCRIPTION`, `DRIVER_CONFIGS`, `DRIVER_DIRS`, `DRIVER_MODULES`, `DRIVER_LOAD_ORDER`, `DRIVER_SEARCH_ROOTS`, `DRIVER_FIRMWARE`, `DRIVER_REQUIRES` are set for that driver. Requires `DRIVER_ROOT` to point at the repo root before sourcing.

- [ ] **Step 1: Create the DVB manifest**

Create `drivers/dvb/manifest.sh` with exactly this content. The values are copied verbatim from `2_build_dvb.sh` and `apply_patches.py` — do not correct anything, the first build is a regression test.

```sh
#!/bin/sh
# DVB family: Hauppauge WinTV-dualHD (USB 2040:8265) on a TS-X51.
# Values mirror the pre-plugin builder exactly. See docs/03 section 9.1.
DRIVER_NAME="dvb"
DRIVER_DESCRIPTION="Hauppauge WinTV-dualHD: em28xx bridge, Si2168 demod, Si2157 tuner"
DRIVER_CONFIGS="CONFIG_MEDIA_SUPPORT=y CONFIG_MEDIA_CAMERA_SUPPORT=y CONFIG_VIDEO_DEV=y \
CONFIG_VIDEO_V4L2=y CONFIG_VIDEO_V4L2_SUBDEV_API=y CONFIG_DVB_CORE=y \
CONFIG_DVB_NET=m CONFIG_DVB_DEMUX=m CONFIG_USB=y CONFIG_USB_SUPPORT=y \
CONFIG_USB_COMMON=m CONFIG_USB_CORE=m CONFIG_VIDEOBUF2_CORE=y \
CONFIG_VIDEOBUF2_MEMOPS=m CONFIG_VIDEOBUF2_VMALLOC=m CONFIG_VIDEOBUF2_DMA_CONTIG=m \
CONFIG_VIDEOBUF2_DMA_SG=m CONFIG_V4L2_MEM2MEM_DEV=y CONFIG_RC_CORE=m \
CONFIG_RC_DEVICES=y CONFIG_VIDEO_EM28XX=m CONFIG_VIDEO_EM28XX_V4L2=m \
CONFIG_VIDEO_EM28XX_DVB=m CONFIG_VIDEO_EM28XX_RC=m CONFIG_DVB_SI2165=m \
CONFIG_DVB_SI2168=m CONFIG_MEDIA_TUNER_SI2157=m CONFIG_DVB_USB=m \
CONFIG_DVB_USB_V2=m CONFIG_DVB_TUNER_XC5000=m CONFIG_DVB_TUNER_DIB0070=m"
DRIVER_DIRS="drivers/media/usb/em28xx drivers/media/dvb-frontends \
drivers/media/tuners drivers/media/dvb-core drivers/media/usb/dvb-usb \
drivers/media/v4l2-core drivers/media/common drivers/media/i2c"
# dvb-core and v4l2-common are listed for build parity, but their configs below
# are =y, and a =y symbol cannot emit a .ko — expect [MISS] for both at collect
# time. If that is what you see, delete the two entries: they are built-in
# dependencies of the modules that matter, not collectible modules.
DRIVER_MODULES="em28xx em28xx-v4l2 em28xx-dvb si2168 si2157 dvb-core dvb-usb \
v4l2-common tveeprom tuner videobuf2-common videobuf2-memops videobuf2-v4l2 \
videobuf2-vmalloc"
DRIVER_LOAD_ORDER="videobuf2-common videobuf2-memops videobuf2-v4l2 \
videobuf2-vmalloc tuner tveeprom si2157 si2168 dvb-usb em28xx em28xx-dvb"
DRIVER_SEARCH_ROOTS="drivers/media"
DRIVER_FIRMWARE="dvb-demod-si2168-b40-01.fw dvb-demod-si2168-d60-01.fw \
dvb-demod-si2168-02.fw"
DRIVER_REQUIRES=""
```

- [ ] **Step 2: Create the USB-serial manifest**

Create `drivers/usb-serial/manifest.sh`:

```sh
#!/bin/sh
# USB-serial bridges, so a USB-TTL cable attached to the NAS enumerates as
# /dev/ttyUSB0 (e.g. a serial console link). Only the matching chip binds.
DRIVER_NAME="usb-serial"
DRIVER_DESCRIPTION="USB-serial bridges: FTDI, CH340, PL2303, CP210x"
DRIVER_CONFIGS="CONFIG_USB_SERIAL=m CONFIG_USB_SERIAL_FTDI_SIO=m \
CONFIG_USB_SERIAL_CH341=m CONFIG_USB_SERIAL_PL2303=m CONFIG_USB_SERIAL_CP210X=m"
DRIVER_DIRS="drivers/usb/serial"
DRIVER_MODULES="usbserial ftdi_sio ch341 pl2303 cp210x"
# usbserial first: the chip drivers resolve usb_serial_register_drivers against it.
DRIVER_LOAD_ORDER="usbserial ftdi_sio ch341 pl2303 cp210x"
DRIVER_SEARCH_ROOTS="drivers/usb/serial"
DRIVER_FIRMWARE=""
DRIVER_REQUIRES=""
```

Note what is *absent*: `CONFIG_USB=y`. `dvb` owns that key; restating it would manufacture a conflict out of agreement.

- [ ] **Step 3: Add `DRIVERS=` to `.env.example`**

Insert after the `OUT_DIR` line in `.env.example`:

```
# Driver families to build, by manifest directory name under drivers/.
DRIVERS="dvb usb-serial"
```

- [ ] **Step 4: Write the driver library**

Create `scripts/lib-drivers.sh`. It is POSIX `sh` (no `local`) because the boot loader sources it under busybox ash.

```sh
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
# transitively) into manifest paths, requires first. Fails on an unknown name.
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
```

- [ ] **Step 5: Write the failing check first — confirm the current verifier is manifest-blind**

Run: `sh scripts/verify-module-list.sh`
Expected: `OK: all 11 modules ...` — it passes today by regex-parsing `load-dvb.sh`, which is exactly why it cannot see manifests. This step records the baseline; the next step replaces it.

- [ ] **Step 6: Rewrite the verifier**

Replace the whole of `scripts/verify-module-list.sh`:

```sh
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
```

- [ ] **Step 7: Run it — expect pass**

Run: `sh scripts/verify-module-list.sh`
Expected: `OK: 2 manifest(s) valid; DRIVERS='dvb usb-serial'; load order agrees with the module lists`, followed by three `WARN:` lines naming `em28xx-v4l2`, `dvb-core`, `v4l2-common` for the `dvb` family. Exit 0.

This is Review Focus item 7, pinned.

- [ ] **Step 8: Break `DRIVER_LOAD_ORDER` and confirm the assert fires**

Run:
```sh
sh -c 'sed "s/^DRIVER_LOAD_ORDER=\"usbserial/DRIVER_LOAD_ORDER=\"nosuchmod usbserial/" drivers/usb-serial/manifest.sh > /tmp/m.bad && cp drivers/usb-serial/manifest.sh /tmp/m.orig && cp /tmp/m.bad drivers/usb-serial/manifest.sh && sh scripts/verify-module-list.sh; echo "exit=$?"; cp /tmp/m.orig drivers/usb-serial/manifest.sh'
```
Expected: `FAIL: ... usb-serial: DRIVER_LOAD_ORDER entry 'nosuchmod' is not in DRIVER_MODULES`, `exit=1`. The manifest is restored by the same command.

- [ ] **Step 9: Break `DRIVER_NAME` and confirm**

Run:
```sh
sh -c 'cp drivers/dvb/manifest.sh /tmp/m.orig && sed "s/^DRIVER_NAME=\"dvb\"/DRIVER_NAME=\"dvbx\"/" /tmp/m.orig > drivers/dvb/manifest.sh && sh scripts/verify-module-list.sh; echo "exit=$?"; cp /tmp/m.orig drivers/dvb/manifest.sh'
```
Expected: `FAIL: ... DRIVER_NAME='dvbx' does not match its directory`, `exit=1`.

- [ ] **Step 10: Confirm the built-but-never-loaded warning is real, not noise**

Run: `sh scripts/verify-module-list.sh 2>&1 | grep WARN`
Expected: three lines, one each for `em28xx-v4l2`, `dvb-core`, `v4l2-common`, all attributed to `dvb`. These are Review Focus item 6 (`dvb-core`, `v4l2-common` cannot emit a `.ko` under `=y`) and item 7 (`em28xx-v4l2` is built, installed, and never loaded — spec open item 2). The verifier must keep reporting them until a decision is made; do not silence them.

- [ ] **Step 11: Confirm the bashism guard, and that `sh -n` alone would not have caught it**

Run:
```sh
printf 'DRIVER_NAME="x"\nDRIVER_MODULES=(a b)\n' > /tmp/notposix.sh
sh -n /tmp/notposix.sh; echo "sh   -n exit=$?"
bash -n /tmp/notposix.sh; echo "bash -n exit=$?"
grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\(|[[:space:]]\[\[|^[[:space:]]*local[[:space:]]' /tmp/notposix.sh; echo "guard exit=$?"
```
Expected: `sh -n` exit **0** and `bash -n` exit 0 — the array is legal to both, because on macOS `/bin/sh` *is* bash — and the grep guard exit 0 with the offending line printed.

This is why step 6's verifier cannot rely on `sh -n` alone: the manifest would pass every check on the developer's machine and fail on the NAS at boot, which is the worst place to find out. `sh -n` is still worth keeping because it does catch this on Linux, where `/bin/sh` is dash, and on CI.

Also confirm the guard leaves the real manifests alone:

Run: `grep -nE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\(|[[:space:]]\[\[|^[[:space:]]*local[[:space:]]' drivers/*/manifest.sh; echo "clean=$?"`
Expected: no output, `clean=1` (grep found nothing). The DVB manifest's comment contains `(USB 2040:8265)` — that must not match, and the pattern's requirement of `NAME=(` is what keeps it out.

- [ ] **Step 12: Prove the unset-does-not-inherit rule (Review Focus item 2)**

A manifest that omits `DRIVER_FIRMWARE` must not inherit the previous one's list.

Run:
```sh
sh -c '
mkdir -p /tmp/drvtest/drivers/first /tmp/drvtest/drivers/second
printf "DRIVER_NAME=first\nDRIVER_DESCRIPTION=d\nDRIVER_CONFIGS=A=y\nDRIVER_DIRS=d\nDRIVER_MODULES=a\nDRIVER_LOAD_ORDER=a\nDRIVER_SEARCH_ROOTS=d\nDRIVER_FIRMWARE=leaked.fw\n" > /tmp/drvtest/drivers/first/manifest.sh
printf "DRIVER_NAME=second\nDRIVER_DESCRIPTION=d\nDRIVER_CONFIGS=B=m\nDRIVER_DIRS=d\nDRIVER_MODULES=b\nDRIVER_LOAD_ORDER=b\nDRIVER_SEARCH_ROOTS=d\n" > /tmp/drvtest/drivers/second/manifest.sh
DRIVER_ROOT=/tmp/drvtest sh -c ". '$PWD/scripts/lib-drivers.sh'; driver_source /tmp/drvtest/drivers/first/manifest.sh; driver_source /tmp/drvtest/drivers/second/manifest.sh; echo \"second DRIVER_FIRMWARE=[\${DRIVER_FIRMWARE:-}]\""
'
```
Expected: `second DRIVER_FIRMWARE=[]` — empty, not `leaked.fw`. If it printed `leaked.fw`, `driver_source` is not clearing the contract variables and a driver could silently inherit another's firmware or load order.

- [ ] **Step 13: Confirm an unknown driver name fails loudly (Review Focus item 1)**

Run:
```sh
sh -c 'cd "$PWD" && DRIVER_ROOT="$PWD" sh -c ". scripts/lib-drivers.sh; driver_load_enabled dvb nosuchdriver; echo exit=\$?"'
```
Expected: `unknown driver 'nosuchdriver'. Available: dvb usb-serial` and `exit=1`.

- [ ] **Step 14: Confirm a CONFIG conflict fails loudly (Review Focus item 4)**

Run:
```sh
sh -c '
mkdir -p /tmp/cfgtest/drivers/aa /tmp/cfgtest/drivers/bb
for d in aa bb; do printf "DRIVER_NAME=$d\nDRIVER_DESCRIPTION=d\nDRIVER_CONFIGS=\"CONFIG_USB=y\"\nDRIVER_DIRS=d\nDRIVER_MODULES=m\nDRIVER_LOAD_ORDER=m\nDRIVER_SEARCH_ROOTS=d\n" > /tmp/cfgtest/drivers/$d/manifest.sh; done
sed -i.bak "s/CONFIG_USB=y/CONFIG_USB=m/" /tmp/cfgtest/drivers/bb/manifest.sh
DRIVER_ROOT=/tmp/cfgtest sh -c ". '$PWD/scripts/lib-drivers.sh'; driver_check_config_conflicts /tmp/cfgtest/drivers/aa/manifest.sh /tmp/cfgtest/drivers/bb/manifest.sh; echo exit=\$?"
'
```
Expected: `CONFIG conflict on CONFIG_USB: 'aa' declares CONFIG_USB=y, 'bb' declares CONFIG_USB=m` and `exit=1`. This is the guard that stops a silent `=y`→`=m` flip, which is design invariant 4's failure mode.

- [ ] **Step 15: Confirm agreement is *not* a conflict**

Run the same as step 14 but leave both manifests at `CONFIG_USB=y` (drop the `sed`).
Expected: exit 0, no output. Agreement must be silent, or every future driver gets blocked for restating a shared value correctly.

- [ ] **Step 16: Clean up fixtures and syntax-check**

Run:
```sh
rm -rf /tmp/drvtest /tmp/cfgtest /tmp/notposix.sh /tmp/m.orig /tmp/m.bad
sh -n scripts/lib-drivers.sh && bash -n scripts/lib-drivers.sh && sh -n scripts/verify-module-list.sh && for f in drivers/*/manifest.sh; do sh -n "$f" && bash -n "$f"; done && echo "syntax OK"
```
Expected: `syntax OK`.

- [ ] **Step 17: Run the secrets check**

Run: `sh scripts/check-secrets.sh`
Expected: `OK: nothing publishable in ...`, exit 0.

- [ ] **Step 18: Commit**

```bash
git add drivers/ scripts/lib-drivers.sh scripts/verify-module-list.sh .env.example
git commit -m "feat: describe drivers as manifests, with a verifier that enforces the contract

Adds drivers/{dvb,usb-serial}/manifest.sh and scripts/lib-drivers.sh, which
loads and validates them and merges their CONFIG entries with conflict
detection. verify-module-list.sh is rewritten around the manifests and no
longer regex-parses the loader.

Nothing consumes the manifests yet."
```

---

## Task 2: `apply_configs.py` — a driver-neutral config writer

**Files:**
- Create: `apply_configs.py`
- Delete: `apply_patches.py` (removed in Task 3 once the builder stops calling it)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `apply_configs.py <config-file> KEY=VALUE [KEY=VALUE ...]` → exit 0 on success, 2 on a malformed token. Replaces each existing `KEY=` line's value; appends keys not present. Task 3 calls this.

- [ ] **Step 1: Write the test fixture and the failing expectations**

Create a fixture config and record what the current script does to it:

```sh
mkdir -p /tmp/cfgtest && printf 'CONFIG_USB=m\n# CONFIG_DVB_USB is not set\nCONFIG_OTHER=y\n' > /tmp/cfgtest/.config
python3 -m py_compile apply_patches.py && echo "current script compiles"
```
Expected: `current script compiles`. There is no passing test yet — the new script does not exist.

- [ ] **Step 2: Confirm the new script is absent**

Run: `python3 apply_configs.py /tmp/cfgtest/.config CONFIG_USB=y; echo "exit=$?"`
Expected: an error and non-zero exit (`can't open file`). This is the failing state.

- [ ] **Step 3: Write `apply_configs.py`**

```python
#!/usr/bin/env python3
"""Write KEY=VALUE tokens into a kernel .config.

Driver-neutral on purpose: every value this writes comes from a driver
manifest (drivers/<name>/manifest.sh), so this script knows nothing about any
particular driver. The =y/=m split it writes is load-bearing — see
docs/03-modular-driver-builder-design.md invariant 4.

    apply_configs.py <config-file> KEY=VALUE [KEY=VALUE ...]
"""
import sys


def parse_tokens(tokens):
    wanted = {}
    for token in tokens:
        key, sep, value = token.partition("=")
        if not sep or not key:
            sys.stderr.write("apply_configs.py: not a KEY=VALUE token: %s\n" % token)
            return None
        wanted[key] = value
    return wanted


def apply(cfg_path, wanted):
    with open(cfg_path) as handle:
        lines = handle.read().split("\n")

    replaced = set()
    for index, line in enumerate(lines):
        for key, value in wanted.items():
            # The "=" guards against CONFIG_USB matching CONFIG_USB_SERIAL.
            if line.startswith(key + "="):
                replaced.add(key)
                lines[index] = key + "=" + value

    for key, value in wanted.items():
        if key not in replaced:
            lines.append(key + "=" + value)

    with open(cfg_path, "w") as handle:
        handle.write("\n".join(lines))

    return len(wanted)


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    wanted = parse_tokens(argv[2:])
    if wanted is None:
        return 2
    apply(argv[1], wanted)
    print("Applied %d config entries to %s" % (len(wanted), argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 4: Run the test — expect pass**

Run:
```sh
printf 'CONFIG_USB=m\n# CONFIG_DVB_USB is not set\nCONFIG_OTHER=y\n' > /tmp/cfgtest/.config
python3 apply_configs.py /tmp/cfgtest/.config CONFIG_USB=y CONFIG_USB_SERIAL=m && cat /tmp/cfgtest/.config
```
Expected:
```
Applied 2 config entries to /tmp/cfgtest/.config
CONFIG_USB=y
# CONFIG_DVB_USB is not set
CONFIG_OTHER=y
CONFIG_USB_SERIAL=m
```
`CONFIG_USB` replaced in place; `CONFIG_USB_SERIAL` appended.

- [ ] **Step 5: Confirm the prefix trap is avoided**

Run: `grep -c '^CONFIG_USB=y$' /tmp/cfgtest/.config && grep -c '^CONFIG_USB_SERIAL=m$' /tmp/cfgtest/.config`
Expected: `1` and `1`. If `CONFIG_USB=y` matched inside `CONFIG_USB_SERIAL=`, the second count would be wrong — this is why the match includes the `=`.

- [ ] **Step 6: Confirm a malformed token is rejected**

Run: `python3 apply_configs.py /tmp/cfgtest/.config NOSEPARATOR; echo "exit=$?"`
Expected: `apply_configs.py` reports that `NOSEPARATOR` is not a `KEY=VALUE` pair, and prints `exit=2`.

- [ ] **Step 7: Confirm the pre-existing `# ... is not set` behaviour is unchanged**

Run: `python3 apply_configs.py /tmp/cfgtest/.config CONFIG_DVB_USB=m && grep -n 'DVB_USB' /tmp/cfgtest/.config`
Expected: both the original `# CONFIG_DVB_USB is not set` line and a new `CONFIG_DVB_USB=m` line. This matches the pre-plugin script exactly: it did not rewrite commented `is not set` lines. Kconfig takes the last value, so this is harmless — **do not "fix" it here**; it would be a behaviour change in the same commit as a refactor.

- [ ] **Step 8: Syntax-check and run the secrets check**

Run: `python3 -m py_compile apply_configs.py && sh scripts/check-secrets.sh`
Expected: `OK: nothing publishable in ...`.

- [ ] **Step 9: Commit**

```bash
git add apply_configs.py
git commit -m "feat: driver-neutral config writer replacing the hardcoded patch list

apply_configs.py takes KEY=VALUE tokens on the command line instead of
carrying 31 DVB entries of its own. The values now come from the driver
manifests; this script knows nothing about any driver.

apply_patches.py is left in place for now and removed once the builder
stops calling it."
```

---

## Task 3: The builder becomes driver-driven

**Files:**
- Rename: `2_build_dvb.sh` → `2_build_modules.sh`
- Rename: `Dockerfile.dvb` → `Dockerfile`
- Delete: `apply_patches.py`
- Modify: `docker_entrypoint.sh`, `0_prepare.sh`

**Interfaces:**
- Consumes: `driver_load_enabled`, `driver_source`, `driver_validate`, `driver_merge_configs` (Task 1); `apply_configs.py` (Task 2).
- Produces: a build that emits `/modules-out/*.ko` for the union of `DRIVERS`. `DRY_RUN=1` prints the resolved plan and exits without downloading or building — Task 4 does not use it, but the tests here do.

- [ ] **Step 1: Rename the files**

```bash
git mv 2_build_dvb.sh 2_build_modules.sh
git mv Dockerfile.dvb Dockerfile
git rm apply_patches.py
```
Expected: `git status` shows three staged renames/deletions.

- [ ] **Step 2: Point the entrypoint and prepare script at the new names**

In `docker_entrypoint.sh`, change the final `exec` line to:

```sh
    exec ./2_build_modules.sh
```

In `0_prepare.sh`, add the driver list to the generated env block, immediately after the `OUT_DIR=` line inside `build_environment`:

```
# Driver families to build, by manifest directory name under drivers/
DRIVERS="dvb usb-serial"
```

- [ ] **Step 3: Confirm the builder still refers to the removed patcher**

Run: `grep -n 'apply_patches\|MODULES_LIST\|MODULE_DIRS\|drivers/media' 2_build_modules.sh`
Expected: matches for `apply_patches.py`, `MODULES_LIST=`, `MODULE_DIRS=`, and `find drivers/media` — the literals being replaced next.

- [ ] **Step 4: Replace the config-patch function**

In `2_build_modules.sh`, after `. build_env.sh`, add the library and root:

```bash
. build_env.sh

export DRIVER_ROOT="$BASE_DIR"
. "$BASE_DIR/scripts/lib-drivers.sh"

# When set, resolve the driver manifests and print the build plan without
# downloading the GPL source or compiling anything. Seconds instead of an hour.
DRY_RUN="${DRY_RUN:-0}"
```

Replace `apply_config_patches()` entirely:

```bash
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
```

- [ ] **Step 5: Add the plan printer**

Add above `function build()`:

```bash
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
```

- [ ] **Step 6: Rewrite the top of `build()`**

Open `2_build_modules.sh` and find `function build() {`. Make exactly three changes to it, and touch nothing else:

**(a)** Insert immediately after `pushd "$SRC_DIR"`:

```bash
    local manifests
    echo "==> Resolving driver manifests (DRIVERS='$DRIVERS')..."
    if ! manifests=$(driver_load_enabled $DRIVERS); then
        echo "ERROR: cannot resolve DRIVERS='$DRIVERS'" >&2
        return 1
    fi

    if [ "$DRY_RUN" = "1" ]; then
        print_build_plan "$manifests" || return 1
        popd
        return 0
    fi
```

**(b)** Leave the whole GPL download/extract block — from `if [[ ! -d "$QNAP_DIR" ]]; then` through the closing `fi` — **exactly as it is**. Do not retype it and do not reformat it; it works and nothing about it is driver-specific.

**(c)** Leave the config-copy block and the `cp "$QNAP_KERNEL_CONFIG_FILE" "$KERNEL_DIR/.config"` line as they are, then change the line after it from the old zero-argument call to:

```bash
    apply_config_patches "$manifests"
```

`local manifests` is what the rest of the function and the two loops below consume; it is already declared at the top of `build()` by change (a), so the build and collect loops reference `$manifests` without redeclaring it.

- [ ] **Step 7: Replace the build loop**

Delete the `MODULES_LIST="..."` and `MODULE_DIRS="..."` literals and the comment above them. Replace the build loop with:

```bash
    echo "==> Building kernel modules (this can take 30-90 minutes)..."
    local build_log="$BASE_DIR/logs/build.log"
    mkdir -p "$BASE_DIR/logs" /modules-out

    for m in $manifests; do
        driver_source "$m" || return 1
        for dir in $DRIVER_DIRS; do
            if [ ! -d "$dir" ]; then
                echo "    [SKIP] $dir (not in this kernel tree)"
                continue
            fi
            echo "    -> [$DRIVER_NAME] building $dir"
            if make ARCH=x86_64 M="$dir" -j"$(nproc)" 2>&1 | tee -a "$build_log" | tail -3; then
                :
            else
                echo "       [WARN] $dir failed to build"
            fi
        done
    done
```

- [ ] **Step 8: Replace the collect loop (Review Focus items 1, 3, 6)**

```bash
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
```

- [ ] **Step 9: Confirm no DVB literal survives in the builder**

Run: `grep -n -i 'dvb\|em28xx\|si2168\|media_dir' 2_build_modules.sh`
Expected: no output. Any hit means a DVB-specific literal is still hardcoded.

- [ ] **Step 10: Test the plan printer with both drivers (Review Focus item 6)**

The builder needs a `.env` to source; the one in this checkout is gitignored. If it is absent, copy the template first — `.env.example` already holds container-absolute paths, which is what the script expects.

Run:
```sh
[ -f .env ] || cp .env.example .env
DRY_RUN=1 ./2_build_modules.sh build
```
Expected: `Enabled drivers (dvb usb-serial):` listing both with their descriptions; the 36 merged CONFIG tokens (31 DVB + 5 serial); a `make ARCH=x86_64 M=drivers/media/usb/em28xx   # [dvb]` line and a `make ARCH=x86_64 M=drivers/usb/serial   # [usb-serial]` line; then the collect section, where the `dvb-core` entry appears as `find drivers/media -name dvb-core.ko -print -quit   # [dvb]`. No download, no `make`, exit 0.

Note what this test *cannot* show: whether that `find` will actually locate `dvb-core.ko`. Under `CONFIG_DVB_CORE=y` it will not — `[MISS]`, Review Focus item 6 — and the plan printer deliberately shows the command rather than predicting its result. Only a real build settles open item 1.

- [ ] **Step 11: Test an unknown driver name fails loudly (Review Focus item 1)**

Run: `DRY_RUN=1 DRIVERS="dvb nosuch" ./2_build_modules.sh build; echo "exit=$?"`
Expected: `unknown driver 'nosuch'. Available: dvb usb-serial` and a non-zero exit. This must not proceed to build a subset — a typo'd plugin name silently dropping a driver is the failure mode this guards.

- [ ] **Step 12: Test an empty `DRIVERS` fails loudly (Review Focus item 3)**

Run: `DRY_RUN=1 DRIVERS="" ./2_build_modules.sh build; echo "exit=$?"`
Expected: `DRIVER is empty: set DRIVERS= in .env (see .env.example)` and a non-zero exit. Silently building zero modules would look like success.

- [ ] **Step 13: Test a config conflict stops the build (Review Focus item 4)**

Run:
```sh
sh -c 'cp drivers/usb-serial/manifest.sh /tmp/m.orig && sed "s/^DRIVER_CONFIGS=\"CONFIG_USB_SERIAL=m/DRIVER_CONFIGS=\"CONFIG_USB=y CONFIG_USB_SERIAL=m/" /tmp/m.orig > drivers/usb-serial/manifest.sh && DRY_RUN=1 ./2_build_modules.sh build; echo "exit=$?"; cp /tmp/m.orig drivers/usb-serial/manifest.sh'
```
Expected: `CONFIG conflict on CONFIG_USB: 'dvb' declares CONFIG_USB=y, 'usb-serial' declares CONFIG_USB=y` — no wait, the value *matches* (`y`), so this must **pass**. That is the point of Review Focus item 4's sibling: agreement is silent. To see the failure, change the injected value to `m`:
```sh
sh -c 'cp drivers/usb-serial/manifest.sh /tmp/m.orig && sed "s/^DRIVER_CONFIGS=\"CONFIG_USB_SERIAL=m/DRIVER_CONFIGS=\"CONFIG_USB=m CONFIG_USB_SERIAL=m/" /tmp/m.orig > drivers/usb-serial/manifest.sh && DRY_RUN=1 ./2_build_modules.sh build; echo "exit=$?"; cp /tmp/m.orig drivers/usb-serial/manifest.sh'
```
Expected: `CONFIG conflict on CONFIG_USB: 'dvb' declares CONFIG_USB=y, 'usb-serial' declares CONFIG_USB=m`, non-zero exit, and the manifest restored.

- [ ] **Step 14: Test a serial-only build (the `DRIVER_REQUIRES` / no-DVB path)**

Run: `DRY_RUN=1 DRIVERS="usb-serial" ./2_build_modules.sh build 2>&1 | head -30`
Expected: only `usb-serial` listed; 5 CONFIG tokens; `make ARCH=x86_64 M=drivers/usb/serial`. This proves a driver does not depend on DVB being enabled.

- [ ] **Step 15: Syntax-check, secrets check**

Run:
```sh
bash -n 2_build_modules.sh && sh -n docker_entrypoint.sh 0_prepare.sh && sh scripts/verify-module-list.sh >/dev/null && sh scripts/check-secrets.sh
```
Expected: `OK: nothing publishable in ...`.

- [ ] **Step 16: Commit**

```bash
git add -A 2_build_dvb.sh 2_build_modules.sh Dockerfile Dockerfile.dvb apply_patches.py docker_entrypoint.sh 0_prepare.sh
git commit -m "feat: driver-driven build; drop the DVB literals from the builder

2_build_modules.sh resolves DRIVERS through scripts/lib-drivers.sh, merges
the enabled drivers' CONFIG entries with conflict detection, builds each
manifest's DRIVER_DIRS and collects through its DRIVER_SEARCH_ROOTS.

Adds DRY_RUN=1, which resolves and prints the plan without downloading or
compiling — the only way to test the wiring in seconds.

apply_patches.py is removed; apply_configs.py does the writing and the
values come from drivers/dvb/manifest.sh."
```

---

## Task 4: The loader becomes driver-driven, with a shim for the old path

**Files:**
- Rename: `scripts/load-dvb.sh` → `scripts/load-modules.sh`
- Create: `scripts/load-dvb.sh` (shim)
- Modify: `verify-module-list.sh` if it still references the old name

**Interfaces:**
- Consumes: `driver_list_manifests`, `driver_source` (Task 1).
- Produces: `scripts/load-modules.sh` — the boot entry point; `DRY_RUN=1` prints the install/firmware/insmod plan without touching `/lib/modules`.

- [ ] **Step 1: Rename the loader**

```bash
git mv scripts/load-dvb.sh scripts/load-modules.sh
```

- [ ] **Step 2: Replace the header**

At the top of `scripts/load-modules.sh`, replace the header block down to the log redirect:

```sh
#!/bin/sh
# Load every driver family's modules on QNAP boot.
#
# QTS wipes /lib/modules/$(uname -r)/extra at every boot and has no autoload
# for out-of-tree modules, so this reinstalls and insmods them. The project
# root is auto-detected from this script's location.
#
# DRY_RUN=1 prints what it would do without touching /lib/modules.
PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
DRIVER_ROOT="$PROJECT_DIR"
. "$PROJECT_DIR/scripts/lib-drivers.sh"
MODULE_DIR="/lib/modules/$(uname -r)/extra"
LOG_FILE="${PROJECT_DIR}/logs/module-boot.log"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "${PROJECT_DIR}/logs"
exec 1>"$LOG_FILE" 2>&1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting module load (project: $PROJECT_DIR)"
```

- [ ] **Step 3: Replace the install block with a dry-run-aware one**

```sh
# QTS wipes /lib/modules/<kernel>/extra on reboot, so reinstall compiled modules.
if [ ! -d "${PROJECT_DIR}/modules" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: compiled module backup not found at ${PROJECT_DIR}/modules"
    exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DRY_RUN: would install ${PROJECT_DIR}/modules/*.ko into ${MODULE_DIR} and run depmod -a"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installing modules to ${MODULE_DIR}"
    mkdir -p "${MODULE_DIR}"
    cp -f "${PROJECT_DIR}/modules/"*.ko "${MODULE_DIR}/"
    depmod -a "$(uname -r)"
fi
```

- [ ] **Step 4: Replace the firmware loop**

```sh
# Ensure firmware is installed in /lib/firmware (QTS updates may wipe it).
for m in $(driver_list_manifests); do
    driver_source "$m" || continue
    for fw in $DRIVER_FIRMWARE; do
        if [ "$DRY_RUN" = "1" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] DRY_RUN: would sync firmware $fw [$DRIVER_NAME]"
        elif [ -f "${PROJECT_DIR}/firmware/$fw" ]; then
            if [ ! -e "/lib/firmware/$fw" ] || [ "${PROJECT_DIR}/firmware/$fw" -nt "/lib/firmware/$fw" ]; then
                cp -f "${PROJECT_DIR}/firmware/$fw" /lib/firmware/$fw
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installed / refreshed firmware: $fw [$DRIVER_NAME]"
            fi
        fi
    done
done
```

- [ ] **Step 5: Replace the module loop**

```sh
# Make sure USB devices have enumerated before loading drivers.
[ "$DRY_RUN" = "1" ] || sleep 3

# Load modules in each driver's declared order. Kernel module names use
# underscores while the compiled files use dashes, so map filename -> loaded
# name for the check. insmod, not modprobe: these are outside the depmod
# search path until the install above has run.
for m in $(driver_list_manifests); do
    driver_source "$m" || continue
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Driver: $DRIVER_NAME ($DRIVER_DESCRIPTION)"
    for mod in $DRIVER_LOAD_ORDER; do
        mod_loaded=$(echo "$mod" | tr '-' '_')
        if [ ! -f "${MODULE_DIR}/${mod}.ko" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Module not found: ${MODULE_DIR}/${mod}.ko [$DRIVER_NAME]"
            continue
        fi
        if [ "$DRY_RUN" = "1" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] DRY_RUN: would insmod ${MODULE_DIR}/${mod}.ko [$DRIVER_NAME]"
            continue
        fi
        if lsmod | grep -q "^${mod_loaded} "; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Module already loaded: $mod"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Loading module: $mod"
            insmod "${MODULE_DIR}/${mod}.ko" 2>&1 || echo "WARN: failed to load $mod"
        fi
    done
done
```

- [ ] **Step 6: Replace the tail**

```sh
[ "$DRY_RUN" = "1" ] || sleep 2

echo "[$(date '+%Y-%m-%d %H:%M:%S')] DVB adapters:"
ls -la /dev/dvb 2>&1 || echo "No /dev/dvb found"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Serial ports:"
ls -la /dev/ttyUSB* 2>&1 || echo "No /dev/ttyUSB* found"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Done"
```

- [ ] **Step 7: Confirm the loader no longer names any driver**

Run: `grep -n -i 'dvb\|em28xx\|si2168\|videobuf2' scripts/load-modules.sh`
Expected: matches only inside the two `ls`/`echo` lines that *report* `/dev/dvb`. No module names, no load order, no firmware list.

- [ ] **Step 8: Test the dry run**

Run: `DRY_RUN=1 sh scripts/load-modules.sh; echo "exit=$?"`
Expected: exit 0. `/lib/modules` untouched (the script bails if `modules/` is absent, which is the correct behaviour on this machine — if `modules/` is empty, `mkdir -p modules` first, or note that the guard fired and check the message).

Then read `logs/module-boot.log`. Expected order, per driver: `usbserial, ftdi_sio, ch341, pl2303, cp210x` (usb-serial) and `videobuf2-common … em28xx-dvb` (dvb), each line tagged with its driver. `usbserial` **before** `ftdi_sio` — that ordering is design invariant 7 and the only thing keeping the chip drivers loadable.

- [ ] **Step 9: Create the shim (Review Focus item 5)**

Create `scripts/load-dvb.sh`:

```sh
#!/bin/sh
# Compatibility shim. The loader was renamed to load-modules.sh when the
# builder became driver-agnostic. A QTS startup cron entry or Control Panel
# "Startup" task still pointing at this path would otherwise silently stop
# loading the modules — QTS wipes /lib/modules/<ver>/extra at every boot, so
# the symptom would be a missing /dev/dvb after a reboot, with nothing to
# explain it. Safe to delete once every NAS has been repointed.
exec "$(cd "$(dirname "$0")" && pwd)/load-modules.sh" "$@"
```

- [ ] **Step 10: Confirm the shim reaches the real loader (Review Focus item 5)**

Run: `DRY_RUN=1 sh scripts/load-dvb.sh; echo "exit=$?"; sh -n scripts/load-dvb.sh && echo "shim syntax OK"`
Expected: the same log lines as step 8, `exit=0`, `shim syntax OK`. Re-run `scripts/verify-module-list.sh` too — it must still pass, proving it no longer depends on the loader's filename or its loop text.

- [ ] **Step 11: Commit**

```bash
git add scripts/load-dvb.sh scripts/load-modules.sh
git commit -m "feat: driver-driven boot loader, with the old path kept as a shim

load-modules.sh installs, syncs firmware and insmods each driver's declared
DRIVER_LOAD_ORDER, so usbserial lands before ftdi_sio the same way tuner
lands before the demod. Adds DRY_RUN=1 to print the order without touching
/lib/modules.

scripts/load-dvb.sh survives as a one-line shim: a crontab still pointing at
the old name would otherwise fail silently after a reboot."
```

---

## Task 5: Documentation

**Files:**
- Modify: `docs/01-boot-and-persistence.md`
- Rename: `docs/02-host-contract.md` → `docs/02-dvb-host-contract.md`
- Create: `docs/05-adding-a-driver.md`
- Modify: `docs/03-modular-driver-builder-design.md`, `README.md`, `CLAUDE.md`

**Interfaces:**
- Consumes: everything above — this task documents the shipped state.
- Produces: no code.

- [ ] **Step 1: Rename the DVB contract doc**

```bash
git mv docs/02-host-contract.md docs/02-dvb-host-contract.md
```
Then update any inbound link: `grep -rn '02-host-contract' README.md docs/ CLAUDE.md`
Expected after the fix: matches only in `docs/03-modular-driver-builder-design.md` where it records the old name.

- [ ] **Step 2: Correct the spec where the plan deviates from it**

In `docs/03-modular-driver-builder-design.md`:

- Replace `docs/04-adding-a-driver.md` with `docs/05-adding-a-driver.md` (two occurrences: the layout tree and the definition-of-done list).
- In section 5, delete the **Optional escape hatch** paragraph (`driver_extra_build()` / `driver_extra_collect()`), and in section 3's non-goals reword the "No hook framework" bullet to: "No hook framework. A family is data; nothing today needs logic the manifest cannot express."
- In section 8, replace assert 5's text with: "Each manifest passes `sh -n`, `bash -n`, and a grep for arrays, `[[`, and `local`. `sh -n` alone is not sufficient: where `/bin/sh` is bash (macOS) a bashism passes it and only breaks at boot under busybox ash on the NAS."
- Add to the status line at the top: `Status: design approved; implementation plan in docs/04-modular-driver-builder-plan.md`.

These are the deviations recorded in this plan's *Deviations* section; making the spec agree with the shipped code is part of the work, not optional polish.

- [ ] **Step 3: Reword `docs/01-boot-and-persistence.md`**

Replace the loader name, the log name and the "if you add a module" advice:

- `scripts/load-dvb.sh` → `scripts/load-modules.sh` everywhere (including the crontab example).
- `logs/dvb-boot.log` → `logs/module-boot.log`.
- The load-order paragraph becomes: "modules load in each driver's declared `DRIVER_LOAD_ORDER`; the DVB chain is still `videobuf2-*` → `tuner` → `tveeprom` → `si2157` → `si2168` → `dvb-usb` → `em28xx` → `em28xx-dvb`, and USB-serial is `usbserial` → chip driver."
- The "If you add a module, add it to the loop *and* to `MODULES_LIST`" sentence becomes: "If you add a module, add it to its driver's manifest (`DRIVER_MODULES` and, if it must be loaded, `DRIVER_LOAD_ORDER`), then run `scripts/verify-module-list.sh`."
- Add one paragraph: a crontab still pointing at `scripts/load-dvb.sh` keeps working through the shim, which should be deleted once repointed.

- [ ] **Step 4: Write `docs/05-adding-a-driver.md`**

The contract table, the four-step recipe, the usb-serial manifest verbatim as a worked example, the conventions (declare only keys you own; POSIX sh, no arrays; load order declared not derived), what the contract deliberately does not cover, and how to verify:

```markdown
# 05 — Adding a driver family

A driver family is one file: `drivers/<name>/manifest.sh`. The builder, the
boot loader and `scripts/verify-module-list.sh` all read it, so they cannot
disagree about what a family contains.

## The contract

| Variable | Required | Meaning |
|---|---|---|
| `DRIVER_NAME` | yes | Must equal the directory name. The key used in `DRIVERS=`. |
| `DRIVER_DESCRIPTION` | yes | One line, for logs. |
| `DRIVER_CONFIGS` | yes | Space-separated `KEY=VALUE` tokens, written into the kernel `.config`. |
| `DRIVER_DIRS` | yes | `make M=<dir>` subtrees, in dependency order. |
| `DRIVER_MODULES` | yes | `.ko` basenames to collect. |
| `DRIVER_LOAD_ORDER` | yes | `insmod` order. Must be a subset of `DRIVER_MODULES`. |
| `DRIVER_SEARCH_ROOTS` | yes | Where to `find` each `.ko`. |
| `DRIVER_FIRMWARE` | may be empty | Basenames synced into `/lib/firmware`. |
| `DRIVER_REQUIRES` | may be empty | Other driver names that must also be enabled. |

## Conventions

- **POSIX `sh` only** — plain `VAR="…"` assignments, no arrays. The boot loader
  sources manifests under busybox `ash`.
- **Declare only the keys you own.** If another driver already declares
  `CONFIG_USB=y`, do not restate it: agreement is silent, but a restated key
  that later drifts is a build-stopping conflict.
- **Values are data.** The `=y`/`=m` split is load-bearing: a dependency set to
  `=m` that is never built breaks dependents with unresolved `Module.symvers`
  symbols. Never "tidy" a value.
- **Load order is declared, not derived.** Deriving it from symbol dependencies
  breaks at `insmod` time, not build time.

## Recipe

1. Create `drivers/<name>/manifest.sh` with the variables above.
2. Add `<name>` to `DRIVERS=` in `.env`.
3. Run `scripts/verify-module-list.sh`.
4. Build with `DRY_RUN=1` first — it prints the merged config, the `make`
   commands and the `find` commands without downloading anything.

If the family needs work the manifest cannot express, that is a signal to
change this contract rather than to add a hook — see *What the contract does
not cover* below.

## Worked example

`drivers/usb-serial/manifest.sh` — the second family, added to let a USB-TTL
cable enumerate as `/dev/ttyUSB0`:

    #!/bin/sh
    # USB-serial bridges, so a USB-TTL cable attached to the NAS enumerates as
    # /dev/ttyUSB0 (e.g. a serial console link). Only the matching chip binds.
    DRIVER_NAME="usb-serial"
    DRIVER_DESCRIPTION="USB-serial bridges: FTDI, CH340, PL2303, CP210x"
    DRIVER_CONFIGS="CONFIG_USB_SERIAL=m CONFIG_USB_SERIAL_FTDI_SIO=m \
    CONFIG_USB_SERIAL_CH341=m CONFIG_USB_SERIAL_PL2303=m CONFIG_USB_SERIAL_CP210X=m"
    DRIVER_DIRS="drivers/usb/serial"
    DRIVER_MODULES="usbserial ftdi_sio ch341 pl2303 cp210x"
    # usbserial first: the chip drivers resolve usb_serial_register_drivers against it.
    DRIVER_LOAD_ORDER="usbserial ftdi_sio ch341 pl2303 cp210x"
    DRIVER_SEARCH_ROOTS="drivers/usb/serial"
    DRIVER_FIRMWARE=""
    DRIVER_REQUIRES=""

Two things to notice. It declares no `CONFIG_USB`: `dvb` owns that key as `=y`,
and restating a key you agree about is how a conflict gets manufactured. And
the four chip drivers ship together — they are small, only the matching
VID:PID ever binds, and carrying all four means no round trip to identify the
cable; `lsusb` reports which one bound.

## What the contract does not cover

The manifest is data: config entries, dirs, modules, load order, firmware. A
family that needs *logic* the contract cannot express would need a hook in the
builder. No family needs one today, so there is none — a hook that is never
called is a hook that is never tested. If a third family arrives that cannot be
described as data, add the hook then, and give it a per-driver lifetime.

## Verifying

`scripts/verify-module-list.sh` checks every manifest is well-formed, POSIX-
parseable, that `DRIVER_LOAD_ORDER ⊆ DRIVER_MODULES`, that no two enabled
drivers disagree about a `CONFIG_*` value, and that every name in
`.env.example`'s `DRIVERS=` exists. It warns about modules that are built but
never loaded.
```

Write that file to `docs/05-adding-a-driver.md`.

- [ ] **Step 5: Update the README**

- Retitle: `# QNAP Driver Builder`.
- Opening paragraph: builds the kernel modules QTS omits, for a TS-X51; DVB and USB-serial are the two families it currently carries.
- Replace the single `MODULES_LIST` block with a per-driver table (`dvb`: 14 modules; `usb-serial`: 5).
- Replace the "Adding support for other tuners" section with a two-line pointer to `docs/05-adding-a-driver.md`.
- Update the project-layout tree: `Dockerfile`, `2_build_modules.sh`, `drivers/`, `scripts/lib-drivers.sh`, `scripts/load-modules.sh`, `apply_configs.py`.
- Quick start: add `DRIVERS="dvb usb-serial"` to the `.env` step; `docker build -f Dockerfile`.
- Delete every "33 configs" claim — the count is 31 and prose counts rot. Do not replace it with another number.
- Install section: `scripts/load-modules.sh`, and a note that `/dev/ttyUSB0` is what the serial family adds.

- [ ] **Step 6: Update `CLAUDE.md`**

- Pipeline diagram: `Dockerfile`, `2_build_modules.sh`, `drivers/*/manifest.sh`, `scripts/lib-drivers.sh`.
- Invariant 5 becomes: "`DRIVER_LOAD_ORDER` must be a subset of `DRIVER_MODULES` in every manifest, and `DRIVERS=` in `.env.example` must name real manifests. `scripts/verify-module-list.sh` asserts both."
- Invariant 7 becomes: the declared order, naming both chains.
- Add to the conventions: "A new driver family is one file in `drivers/` plus one word in `.env`; never add a driver name to a script."
- Fix the "33 configs" reference in the fixes table.

- [ ] **Step 7: Verify the docs match reality**

Run: `grep -rn 'load-dvb\.sh\|2_build_dvb\|Dockerfile\.dvb\|apply_patches\|MODULES_LIST\|dvb-boot\.log' README.md CLAUDE.md docs/`
Expected: hits only where a shim or the old name is being described as old — in `docs/05` step 9's shim and in `docs/03`'s migration section. Anything else is stale.

- [ ] **Step 8: Full check**

Run:
```sh
sh scripts/verify-module-list.sh && sh scripts/check-secrets.sh && sh -n scripts/*.sh && bash -n 2_build_modules.sh build_env.sh docker_entrypoint.sh 0_prepare.sh && python3 -m py_compile apply_configs.py && echo "ALL OK"
```
Expected: `ALL OK`. The verifier prints its three built-but-never-loaded warnings; that is expected until the `dvb-core`/`v4l2-common` question is settled by a build.

- [ ] **Step 9: Commit**

```bash
git add -A README.md CLAUDE.md docs/
git commit -m "docs: describe the manifest contract and update the renamed paths

Adds docs/05-adding-a-driver.md, renames the host contract to
docs/02-dvb-host-contract.md since it is DVB's contract specifically, and
updates the boot/persistence guide, README and CLAUDE.md for the renamed
scripts and the DRIVERS= selection.

Drops the '33 configs' claim; the real count is 31 and prose counts rot."
```

---

## After the plan

The design's definition of done is not met by any of these tasks alone — it needs a build on a Docker host and a check on the NAS.

**First, add `DRIVERS` to the real host `.env`.** It is gitignored, so no task can edit it, and it was written before `DRIVERS` existed:

```sh
grep -q '^DRIVERS=' .env || printf 'DRIVERS="dvb usb-serial"\n' >> .env
```

Skipping this is safe but noisy — the builder fails loudly with `DRIVER is empty: set DRIVERS= in .env` rather than building nothing, which is exactly what Review Focus item 3 buys.

Then build. `DRIVERS` is read from the `.env` that `Dockerfile` copies into the image — the container has no other way to learn the `/build` paths — so it is set at `docker build` time, not on the `run` line (design invariant 3):

```bash
docker build -t qnap-driver-builder .
docker run --rm --user root \
    -v "$PWD/src:/build/src" -v "$PWD/modules:/modules-out" \
    -v "$PWD/logs:/build/logs" qnap-driver-builder
```

Confirm the image actually got both drivers before starting the 30–90 minute build — this is the same check as Task 3 step 10, run inside the container:

```bash
docker run --rm --entrypoint sh qnap-driver-builder -c 'DRY_RUN=1 ./2_build_modules.sh build'
```

Watch the `[MISS]` lines as the build finishes — that is spec open item 1 being answered.

Then on the NAS: `ls /dev/dvb` unchanged, `ls /dev/ttyUSB0` present once the cable is attached, and `dmesg` naming which chip bound. Two spec open items resolve there: whether `dvb-core`/`v4l2-common` print `[MISS]` (delete both entries from `DRIVER_MODULES` if so), and whether `em28xx-v4l2` needs adding to the DVB load order.
