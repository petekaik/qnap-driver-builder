# Modular driver builder — design

**Date:** 2026-10-08
**Status:** design approved; implementation plan in docs/04-modular-driver-builder-plan.md
**Repo:** `qnap-driver-builder`

## 1. Why

The repository builds the DVB/USB-media kernel modules that QNAP's stock QTS
kernel omits, so a Hauppauge WinTV-dualHD works on an x86_64 QNAP NAS. The name
says `qnap-driver-builder`, but every shared script is shaped around one driver
family: `Dockerfile.dvb`, `2_build_dvb.sh`, `load-dvb.sh`, a Python file whose
only job is 31 hardcoded DVB `CONFIG_*` entries, and a verifier that
regex-parses a `for mod in …` line out of the loader.

The first non-DVB driver is now needed: a **USB-serial bridge driver** so the
NAS can talk to a serial console over a USB-TTL cable (`/dev/ttyUSB0`). Adding
it the current way means editing five shared files and threading DVB-specific
names through code that has nothing to do with DVB.

The goal is that adding a driver family means **adding one file and one word to
`.env`** — not editing the builder, the loader, and the verifier in step.

## 2. Decisions taken

| Question | Decision |
|---|---|
| How far does the restructure reach? | **Full rename.** Everything shared goes family-neutral; DVB becomes plugin #1. |
| What does the USB-serial side deliver? | **Driver only** — `/dev/ttyUSB0` appears. No capture service, no ser2net, no `agetty`. |
| Same NAS as `.env` already targets? | **Yes — one `.env`, one GPL tree.** No device abstraction; `.env` stays per-target and is documented as such. |
| Plugin mechanism | **Declarative manifests**, POSIX-sh, sourced by builder + loader + verifier. |

## 3. Goals and non-goals

**Goals**

- A driver family is described entirely by `drivers/<name>/manifest.sh`.
- Builder, loader and verifier read that one description, so they agree by
  construction rather than by discipline.
- DVB behaviour is *unchanged*: same collected modules, same load order, same
  firmware files.
- USB-serial modules build and load on the same NAS.

**Non-goals**

- No device/multi-target abstraction. One `.env` per target NAS is enough.
- No hook framework. A family is data; nothing today needs logic the manifest
  cannot express.
- No persistence or capture service for the serial console. Attaching is a
  manual operation (section 11).
- No change to the boot-persistence model: QTS still wipes
  `/lib/modules/<version>/extra` every boot.

## 4. Layout

```
Dockerfile                    <- was Dockerfile.dvb
docker_entrypoint.sh          runs 2_build_modules.sh
0_prepare.sh                  writes .env, now including DRIVERS
build_env.sh                  unchanged: sources .env, patch/enter/leave helpers
2_build_modules.sh            <- was 2_build_dvb.sh
apply_configs.py              <- was apply_patches.py, now driver-neutral
drivers/
  dvb/manifest.sh
  usb-serial/manifest.sh
scripts/
  lib-drivers.sh              new: manifest loading and merge/conflict helpers
  load-modules.sh             <- was load-dvb.sh
  load-dvb.sh                 one-line shim -> load-modules.sh (see section 10)
  qnap-install.sh             new here: was NAS-only, see section 10
  dvb-watchdog.sh             new here: was NAS-only, see section 10
  verify-module-list.sh       manifest-aware
docs/
  01-boot-and-persistence.md  reworded family-neutral
  02-dvb-host-contract.md     <- was 02-host-contract.md
  03-modular-driver-builder-design.md  this document
  05-adding-a-driver.md       new: the manifest contract
README.md                     retitled "QNAP Driver Builder"
CLAUDE.md                     invariants restated in manifest terms
```

## 5. The manifest contract

Each `drivers/<name>/manifest.sh` is plain POSIX-sh variable assignments — **no
arrays and no bashisms**, because the NAS-side loader runs under busybox `ash`
and sources the same files.

| Variable | Required | Meaning |
|---|---|---|
| `DRIVER_NAME` | yes | Must equal the directory name. The key used in `DRIVERS=`. |
| `DRIVER_DESCRIPTION` | yes | One line, for logs and docs. |
| `DRIVER_CONFIGS` | yes | Space-separated `KEY=VALUE` tokens, applied to the kernel `.config`. |
| `DRIVER_DIRS` | yes | `make M=<dir>` subtrees, **in dependency order**. |
| `DRIVER_MODULES` | yes | `.ko` basenames to collect. |
| `DRIVER_LOAD_ORDER` | yes | `insmod` order. Must be a subset of `DRIVER_MODULES`. |
| `DRIVER_SEARCH_ROOTS` | yes | Where to `find` each `.ko`. |
| `DRIVER_FIRMWARE` | may be empty | Basenames synced into `/lib/firmware`. |
| `DRIVER_REQUIRES` | may be empty | Other driver names that must also be enabled. |

Space-separated lists, not arrays: `for m in $DRIVER_MODULES` must work in ash.

### 5.1 Conventions

- **Declare only the keys you own.** `usb-serial` declares its
  `CONFIG_USB_SERIAL*=m` entries and says nothing about `CONFIG_USB`, which
  `dvb` already owns as `=y`. Restating a key you agree about manufactures a
  conflict. The merge guard (section 6) fires only on genuine disagreement.
- **Values are data.** The `=y` / `=m` split is carried verbatim in the
  manifest and written verbatim by `apply_configs.py`. There is no logic left
  to "tidy" — this is what invariant 4 protects.
- **Load order is declared, not derived.** Deriving it from symbol dependencies
  is the change that breaks silently at `insmod` time.

## 6. Build stage — `2_build_modules.sh`

Unchanged: GPL source download/extract, device config copy, `make prepare`,
`make modules_prepare`.

Driver-driven:

1. **Resolve.** Source `scripts/lib-drivers.sh`, then for each name in
   `$DRIVERS`, source `drivers/<name>/manifest.sh`. Unknown name → hard fail
   listing the available drivers. Pull in `DRIVER_REQUIRES` transitively. Fail
   if a required variable is unset. Assert `DRIVER_LOAD_ORDER ⊆
   DRIVER_MODULES` and `DRIVER_MODULES` non-empty.
2. **Patch the config once, for all drivers.** There is exactly one
   `$KERNEL_DIR/.config`, so this is a single merge pass, not one per driver.
   Tokens from every enabled manifest are collected, checked for conflicts, and
   passed to one `apply_configs.py "$KERNEL_DIR/.config" $TOKENS` call.
3. **Build.** For each driver, for each dir in `DRIVER_DIRS` **in declared
   order**, `make ARCH=x86_64 M=<dir> -j$(nproc)`, passing
   `KBUILD_EXTRA_SYMBOLS` the accumulated `Module.symvers` of every directory
   built so far. The order and the accumulation are both load-bearing: `M=`
   makes it an external build, so modpost resolves undefined symbols only
   against the symbols it already knows — QNAP's own plus those named in
   `KBUILD_EXTRA_SYMBOLS`. A directory listed before one that exports what its
   modules need is the difference between the module linking and the module
   silently not existing, because modpost aborts the whole directory on the
   first undefined symbol and only warns. Before building a driver the builder
   deletes the `.ko` it is about to produce, so a stale file cannot be collected
   as `[OK]` when this run failed to produce it. A dir absent from the tree, or
   one whose build fails, warns and continues.
4. **Collect.** For each driver, for each root in `DRIVER_SEARCH_ROOTS`, find
   each `DRIVER_MODULES` entry with `find "$root" -name "$mod.ko" -print -quit`
   and copy it to `/modules-out/`, keeping the `[OK]` / `[MISS]` reporting.

### 6.1 `apply_configs.py`

Signatures and behaviour:

```
apply_configs.py <config-file> KEY=VALUE [KEY=VALUE ...]
```

Replaces every `KEY=` line's value and appends keys not present. The 31-entry
dict is deleted; the values now live in `drivers/dvb/manifest.sh`. The script
becomes a dumb writer with no knowledge of any driver — which is the point.

### 6.2 Merge helper — `scripts/lib-drivers.sh`

Shared by the builder, the verifier and the loader so the manifest rules exist
in exactly one place. POSIX `sh`. The builder calls `driver_load_enabled`,
`driver_source` and `driver_merge_configs`; the verifier uses the
list/load/merge/conflict helpers; the loader uses `driver_list_manifests`
and then `driver_source` directly — after sourcing, the manifest's variables
*are* the accessors, so no `driver_*_of` wrappers exist — and must never call
`driver_load_enabled` (it has no usable `$DRIVERS` on the NAS — see section 7):

- `driver_list_manifests` — absolute paths of `drivers/*/manifest.sh`, sorted.
- `driver_source` — clears the contract variables, then sources one manifest.
- `driver_load_enabled` — sources the manifests named in `$DRIVERS`, fails on an
  unknown name, resolves `DRIVER_REQUIRES`.
- `driver_merge_configs` — concatenates every enabled driver's
  `DRIVER_CONFIGS`, printing the bare `KEY=VALUE` tokens in driver order; each
  key's owner is recorded privately so a conflict can name both drivers.
- `driver_check_config_conflicts` — fails, naming both drivers, when two
  enabled drivers declare the same key with different values.

The conflict check lives here, not in Python, so the verifier can run it
statically with no build and no kernel tree.

## 7. Load stage — `scripts/load-modules.sh`

Same three jobs as today, with the lists coming from the manifests.

**Where the driver list comes from.** Not `.env` — on the NAS those paths are
container-absolute and meaningless, and the loader already auto-detects
`PROJECT_DIR` from its own location. It sources `scripts/lib-drivers.sh` and
uses `driver_list_manifests`, so it sources *every* `drivers/*/manifest.sh` in
sorted order. A driver never built for this NAS contributes modules whose
`.ko` is absent from `modules/`, which the existing `[ -f ]` guard already
reports and skips. No new state, no generated file to keep in sync.

1. Install `modules/*.ko` into `/lib/modules/$(uname -r)/extra`, `depmod -a`.
2. Sync each `DRIVER_FIRMWARE` entry from `firmware/` into `/lib/firmware` when
   missing or older (`-nt`), preserving today's Si2168 behaviour exactly.
3. `sleep 3` for USB enumeration, then `insmod` each `DRIVER_LOAD_ORDER` entry
   in declared order, per driver.

Details:

- Order across drivers is alphabetical and deterministic; order *within* a
  driver is the load-bearing one. The families are independent. If cross-driver
  ordering ever matters, that is a `DRIVER_LOAD_PRIORITY` field added then.
- The `tr '-' '_'` filename→loaded-name mapping stays (`em28xx-dvb.ko` loads as
  `em28xx_dvb`).
- Log file becomes `logs/module-boot.log`; the per-driver load lines name their
  driver (the header, the `WARN` fallbacks and the end-of-run device summary do
  not).
- `insmod` stays, not `modprobe` — unchanged reasoning, unchanged code path.

## 8. Verification — `scripts/verify-module-list.sh`

Becomes manifest-aware and stays a dependency-free `sh` script needing no
Docker and no kernel tree. Asserts:

1. Every required variable is set and non-empty.
2. `DRIVER_NAME` equals its directory name.
3. `DRIVER_LOAD_ORDER ⊆ DRIVER_MODULES`, per driver (invariant 5, on data).
4. No module appears twice in `DRIVER_MODULES`, and `DRIVER_SEARCH_ROOTS` is
   non-empty whenever `DRIVER_MODULES` is. (Which root actually contains a
   given `.ko` cannot be known statically — that is the build's `[MISS]` line.)
5. Each manifest passes `sh -n`, `bash -n`, and a grep for arrays, `[[`, and
   `local`. `sh -n` alone is not sufficient: where `/bin/sh` is bash (macOS) a
   bashism passes it and only breaks at boot under busybox ash on the NAS.
6. Every name in `.env.example`'s `DRIVERS=` resolves to a real directory.
7. No `CONFIG_*` key has conflicting values across enabled drivers.
8. **Warning, not error:** modules collected but absent from every
   `DRIVER_LOAD_ORDER` — installed but never loaded. See open item 3.

The verifier no longer regex-parses the loader, so reformatting a loop can no
longer silently defeat the check.

## 9. Manifests

### 9.1 `drivers/dvb/manifest.sh`

Values mirrored **verbatim** from the pre-rename `2_build_dvb.sh` and
`apply_patches.py`, so the first build is a regression test rather than a
behaviour change. The two `=y` entries that could never be collected were
removed afterwards — see open item 1.

```sh
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
DRIVER_DIRS="drivers/base/regmap drivers/media/dvb-core drivers/media/common \
drivers/media/v4l2-core drivers/media/dvb-frontends drivers/media/tuners \
drivers/media/i2c drivers/media/usb/dvb-usb drivers/media/usb/em28xx"
DRIVER_MODULES="em28xx em28xx-v4l em28xx-dvb em28xx-rc si2168 si2157 dvb-usb \
tveeprom tuner videobuf2-common videobuf2-memops videobuf2-v4l2 videobuf2-vmalloc"
DRIVER_LOAD_ORDER="videobuf2-common videobuf2-memops videobuf2-v4l2 \
videobuf2-vmalloc tuner tveeprom si2157 si2168 dvb-usb em28xx em28xx-rc em28xx-dvb"
DRIVER_SEARCH_ROOTS="drivers/media"
DRIVER_FIRMWARE="dvb-demod-si2168-b40-01.fw dvb-demod-si2168-d60-01.fw \
dvb-demod-si2168-02.fw"
DRIVER_REQUIRES=""
```

Counts are deliberately not stated: they rot, and the earlier "33 configs"
claim was already wrong. `drivers/dvb/manifest.sh` is the authority this block
mirrors.

### 9.2 `drivers/usb-serial/manifest.sh`

```sh
DRIVER_NAME="usb-serial"
DRIVER_DESCRIPTION="USB-serial bridges: FTDI, CH340, PL2303, CP210x"
DRIVER_CONFIGS="CONFIG_USB_SERIAL=m CONFIG_USB_SERIAL_FTDI_SIO=m \
CONFIG_USB_SERIAL_CH341=m CONFIG_USB_SERIAL_PL2303=m CONFIG_USB_SERIAL_CP210X=m"
DRIVER_DIRS="drivers/usb/serial"
DRIVER_MODULES="usbserial ftdi_sio ch341 pl2303 cp210x"
DRIVER_LOAD_ORDER="usbserial ftdi_sio ch341 pl2303 cp210x"
DRIVER_SEARCH_ROOTS="drivers/usb/serial"
DRIVER_FIRMWARE=""
DRIVER_REQUIRES=""
```

`usbserial` before the chip drivers is the invariant-7 fact for this family:
the chip modules resolve `usb_serial_register_drivers` against it.

Four chip drivers rather than one identified chip: they are small, only the
matching VID:PID binds, and shipping all four removes a round trip to identify
the cable. `lsusb` on the NAS reports which one bound. Narrow this to one if
carrying four is unwanted.

### 9.3 `.env`

```
DRIVERS="dvb usb-serial"
```

Added to `.env.example` and to `0_prepare.sh`'s generated block. Documented as
part of the build identity: the build produces the union of the enabled
drivers, and `.env` is per target NAS.

## 10. Migration

**The one thing that can silently break.** The NAS crontab's `@reboot` line
names `scripts/load-dvb.sh`. If it is not updated to
`scripts/load-modules.sh`, nothing complains: QTS wipes
`/lib/modules/<version>/extra` at boot, the tuner quietly stops appearing, and
the only symptom is a missing `/dev/dvb` after some later reboot.

Two mitigations, both cheap and both required:

- `scripts/load-dvb.sh` is **kept** as a one-line shim that `exec`s
  `load-modules.sh`, so a forgotten crontab keeps working.
- The rename is called out in `README.md`, `docs/01` and the commit message.

Nothing else on the NAS moves: same `modules/`, same `firmware/`, same
`/lib/modules/<version>/extra`. Add `DRIVERS=...` to the host `.env`
(gitignored) before rebuilding.

### 10.1 The NAS checkout is a deploy target, not a mirror

Found late, and it explains a long detour: the checkout on the NAS is
**not a clone of this repo and cannot be fast-forwarded to it**. (Its exact
path is machine-specific and deliberately not recorded here.) Both trees root
at a commit titled *"Initial commit: QNAP DVB module builder for Hauppauge
dualHD"* — this repo at `21cbe31`, the NAS at `829e11e` — and the NAS's object
does not exist in this repo at all. They are two unrelated histories that happen
to share one GitHub remote.

The boot-persistence layer made this worse rather than causing it:
`qnap-install.sh`, `dvb-watchdog.sh` and the NAS's `dvb-loader.sh` had been
written **directly on the NAS**, untracked, and never came back here, while this
repo meanwhile took `scripts/` as a tracked path. The same directory name held
two different things, so every "just update the NAS" idea collided with a
working script that existed nowhere else.

Both are settled now. The persistence layer is tracked here (section 4), and the
NAS side is deployed by copying `scripts/`, `modules/` and `firmware/` — never
by `git pull`, which has no common ancestor to merge with. `dvb-loader.sh` is
deliberately **not** carried over: `load-modules.sh` supersedes it, since it
hardcoded the module list that the manifests now own. Two things it had that
`load-modules.sh` did not were ported instead: symlink-safe `PROJECT_DIR`
resolution and real exit codes. A third, its wait for `lsusb` to show the tuner,
was dropped — the match is device-specific and the loader is not — and became a
`USB_SETTLE` delay whose default is the old fixed 3 s. The symlink resolution is
the load-bearing one: QTS runs the loader through `/etc/init.d/dvb-loader.sh`,
where a plain `dirname "$0"` resolves `PROJECT_DIR` to `/etc` and the loader
finds no manifests and silently loads nothing.

## 11. Testing

Per repository convention: plain `sh` scripts, no framework, asserts added to
the existing check rather than a new suite.

- `scripts/verify-module-list.sh` — the eight asserts in section 8.
- `check-secrets.sh` — a user-level tool on `PATH` (`~/.local/bin/`), shared
  across projects and deliberately not vendored here; the new spec and manifests
  must pass it before commit.
- Syntax before commit: `bash -n` on shell, `sh -n` on manifests and POSIX
  scripts, `python3 -m py_compile` on `apply_configs.py`.
- The end-to-end test is unchanged and is the real one: a build, then on the
  NAS `ls /dev/dvb` plus `ls /dev/ttyUSB0`, with `dmesg` checked for which
  serial chip bound.

## 12. Open items and risks

1. **Resolved — `dvb-core` and `v4l2-common` removed from `DRIVER_MODULES`.**
   Their configs are `=y` (`CONFIG_DVB_CORE=y`, `CONFIG_VIDEO_V4L2=y`), and a
   `=y` symbol is linked into the kernel image rather than emitted as a `.ko`:
   `obj-$(CONFIG_DVB_CORE) += dvb-core.o` in `drivers/media/dvb-core/Makefile`,
   and `v4l2-common.o` is one object inside the `=y` `videodev.o` composite in
   `drivers/media/v4l2-core/Makefile`. No build of this configuration can
   produce their `.ko`, so both entries — and the README row that advertised
   them — were deleted rather than left to print `[MISS]` forever. The general
   form stands: any `=y` symbol listed in `DRIVER_MODULES` is uncollectible, and
   the build's `[MISS]` lines are what report it.
2. **`em28xx-v4l` is built and installed but never `insmod`ed** — it is in
   `DRIVER_MODULES` and absent from `DRIVER_LOAD_ORDER`. (The object is
   `em28xx-v4l.o`, from `obj-$(CONFIG_VIDEO_EM28XX_V4L2) += em28xx-v4l.o`; an
   earlier draft called it `em28xx-v4l2`, a name no kernel emits.) It may be a
   genuine missing load (if `em28xx-dvb` resolves symbols against it) or simply
   unused for DVB. Evidence from the target NAS: `em28xx-v4l.ko` is present in
   `/lib/modules/5.10.60-qnap/extra/` and `lsmod` does not list `em28xx_v4l`,
   while both DVB adapters work — so not loading it is not what would break
   DVB. Assert 8 still surfaces it on every verifier run; deciding whether to
   add it to the load order remains a follow-up, because changing it changes
   the DVB path.
3. **Config-merge conflicts** are a hard error naming both drivers. A driver
   declaring only what it owns (section 5.1) keeps the guard quiet.
4. **First load: verified on the target NAS, 2026-10-08.** QTS 5.2.9 ships
   `usbserial.ko`, `ftdi_sio.ko`, `pl2303.ko` and `cp210x.ko` — but they sit
   **flat in `/lib/modules/5.10.60-qnap/`**, not under the
   `kernel/drivers/usb/serial/` path an in-tree kernel uses, which is why a
   `find` for the documented layout comes up empty. Only **`ch341.ko`** is
   absent, so `ch341` is the one module this family actually adds there.

   The risk this item used to flag did not materialise. Both cross-built
   modules were `insmod`ed against the running kernel and both loaded clean:
   `ch341` bound to QTS's resident `usbserial` with no symbol-CRC or vermagic
   complaint, and `ftdi_sio` drove a real FTDI FT230X to `/dev/ttyUSB0` and read
   a `cubox-2 login:` prompt at 115200 8N1. So modules built against the
   newest *published* source, QTS 5.2.3, do load on a NAS running 5.2.9.

   One thing worth knowing: QTS ships `ftdi_sio.ko` but never loads it. The
   FT230X sat on the bus with no driver bound and no `/dev/ttyUSB0` until the
   module was `insmod`ed by hand, so a QTS-shipped module is not the same as a
   QTS-loaded one — check `lsmod`, not `ls /lib/modules`.
5. **A build is a superset.** With `DRIVERS="dvb usb-serial"` the loader loads a
   module that a given NAS was not built for as a logged "not found", not an
   error. Stated rather than discovered.
6. **Build time is unchanged** (30–90 min for the media subtrees); the serial
   modules add seconds.
7. **A whole-tree `make modules` cannot be the build, and this is QNAP's bug,
   not ours.** It was tried, to make symbol resolution a non-issue. It fails:
   `drivers/target/target_core_device.c` and
   `drivers/target/qnap/target_core_qtransport.c` reference members —
   `tp_threshold_hit`, `tp_threshold_percent`, `last_hit`, `hit_count` — that
   `struct qnap_se_dev_attr_dr` does not have under the target config this
   build applies, so `drivers/target` does not compile. The consequence is
   total, not partial: the `modules` recipe *is* the final modpost pass that
   emits every `.ko`, and make will not run a target's recipe when a
   prerequisite failed, so nothing at all is emitted — `-k` does not help,
   because the skipped thing is the recipe, not the failing subtree. The
   per-directory build in section 6 is therefore not a convenience; it is what
   keeps this build away from QNAP's unrelated and, here, uncompilable
   storage-target code.
8. **QTS has no `screen`, `picocom` or `stty`** — and busybox's applet list has
   no `stty` either, so a `stty -F /dev/ttyUSB0 115200 raw; cat /dev/ttyUSB0`
   recipe silently reads zero bytes there and looks like a dead cable. What
   does work: Python 2.7 at `/usr/local/bin/python` (2.7, not 3) with `termios`
   and `select` — set `B115200` and `CS8 | CREAD | CLOCAL`, zero
   `iflag`/`oflag`/`lflag`, write `"\r\n"`, then read for a few seconds. That is
   how the item 4 verification was done. Attaching stays a manual operation
   (section 2); the recipe is recorded here only so the next person does not
   conclude the link is broken.

## 13. Definition of done

- `scripts/verify-module-list.sh` passes with both manifests present.
- `check-secrets.sh` passes on the committed tree.
- A build with `DRIVERS="dvb usb-serial"` produces the DVB module set unchanged
  plus `usbserial`, `ftdi_sio`, `ch341`, `pl2303`, `cp210x`.
- On the NAS: `ls /dev/dvb` unchanged, and `ls /dev/ttyUSB0` appears after the
  serial cable is attached.
- `docs/05-adding-a-driver.md` describes the contract, and adding a third
  driver is one new file plus one word in `.env` — except a family with its own
  device node, which also adds a line to the loader's end-of-run device summary.
