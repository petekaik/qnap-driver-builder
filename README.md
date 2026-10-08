# QNAP Driver Builder

Builds the kernel modules that QNAP's stock QTS kernel does not ship, so
hardware QTS ignores works on an x86_64 QNAP NAS. It currently carries two
driver families: **DVB** — a **Hauppauge WinTV-dualHD** (USB `2040:8265`)
DVB-T/T2 stick — and **USB-serial**, so a USB-TTL cable enumerates as
`/dev/ttyUSB0`.

The modules are compiled **in a Docker container** against QNAP's published GPL
kernel source — nothing is built natively on the NAS, which is why this works at
all on a locked-down QTS install.

| | |
|---|---|
| Target device | TS-X51 series (TS-251 / 251+ / 451 / 651 / 851, Celeron J1900, x86_64) |
| Target OS | QTS 5.2.x, kernel `5.10` (`5.10.60-qnap`) |
| Tuner | Hauppauge WinTV-dualHD, USB ID `2040:8265` (em28xx bridge + Si2168 demod + Si2157 tuner) |
| Toolchain | [`mammo0/qnap-qts-toolchain:vivid`](https://github.com/mammo0/qnap-qts-toolchain) |

## Status

The manifests, scripts and configs are checked for syntax and internal
consistency — `scripts/verify-module-list.sh` and `scripts/check-secrets.sh` run
clean. The pipeline has **not** been run end to end from this tree yet; that
proof is a build followed by `ls /dev/dvb` (and `ls /dev/ttyUSB0`) on the NAS.
Treat the first run as the real test, and expect to adjust a manifest's
`DRIVER_DIRS` if your kernel tree lays a subtree out differently.

## Project layout

```
.
├── Dockerfile                # builder image (toolchain + build user uid/gid 1000)
├── docker_entrypoint.sh      # prints toolchain info, runs 2_build_modules.sh
├── 0_prepare.sh              # generates .env (device, QTS version, paths, DRIVERS)
├── build_env.sh              # sources .env, provides patch/enter/leave helpers
├── 2_build_modules.sh        # the build: download GPL source, merge configs, build modules
├── apply_configs.py          # writes DRIVER_CONFIGS into the kernel .config
├── drivers/
│   ├── dvb/manifest.sh       # plugin #1: the WinTV-dualHD DVB chain
│   └── usb-serial/manifest.sh # plugin #2: FTDI / CH340 / PL2303 / CP210x
├── scripts/
│   ├── lib-drivers.sh        # manifest loading, validation and config merging
│   ├── load-modules.sh       # boot loader: reinstall + insmod modules, sync firmware
│   ├── load-dvb.sh           # shim that execs load-modules.sh (delete once repointed)
│   ├── qnap-install.sh       # wires the loader into the boot path, idempotently
│   ├── dvb-watchdog.sh       # 5-minute cron: recovers modules that drop off
│   ├── verify-module-list.sh # asserts the manifests are well formed and agree
│   └── check-secrets.sh      # keeps credentials/IPs/host paths out of commits
├── docs/
│   ├── 01-boot-and-persistence.md  # keeping modules loaded across reboots and QTS updates
│   ├── 02-dvb-host-contract.md     # what a consumer (TVHeadend) needs from the host
│   └── 05-adding-a-driver.md       # the manifest contract and how to add a family
├── firmware/                 # downloaded firmware (gitignored, never shipped)
├── modules/                  # built .ko files (gitignored)
├── logs/                     # build and boot logs (gitignored)
├── src/                      # downloaded GPL kernel tree (gitignored, several GB)
├── .env.example              # container-path .env to copy (see Quick start)
├── .gitignore
└── .dockerignore
```

There is no `1_` script — step 1 is the `docker build` below.

## Build pipeline

1. `build_env.sh` sources `.env`, defining `SRC_DIR`, `KERNEL_DIR`,
   `QNAP_KERNEL_CONFIG_FILE`, `DRIVERS` and friends. **All paths in `.env` must
   be container-absolute** (`/build/...`) — see Quick start.
2. `2_build_modules.sh` resolves the driver manifests named in `DRIVERS` and
   downloads `GPL_QTS-<QNAP_VER>_Kernel.tar.gz` from QNAP's SourceForge GPL
   archive into `$SRC_DIR` (split-file fallback included), then copies the
   device's reference config to `$KERNEL_DIR/.config`.
3. Every enabled manifest's `DRIVER_CONFIGS` tokens are merged and
   conflict-checked in one pass, then written into the `.config` by
   `apply_configs.py`. Then `make prepare` + `modules_prepare` runs, each
   driver's `DRIVER_DIRS` subtrees are built, and the modules named in
   `DRIVER_MODULES` are collected into `/modules-out/`.
4. Mount `/modules-out` to a host directory to collect the modules. The
   `src/` mount caches the several-GB kernel tree between runs.

Modules produced, per family (each manifest's `DRIVER_MODULES`):

| Driver | Modules |
|---|---|
| `dvb` | `em28xx` `em28xx-v4l` `em28xx-dvb` `em28xx-rc` `dvb-usb` `si2168` `si2157` `tuner` `tveeprom` `videobuf2-common` `videobuf2-memops` `videobuf2-v4l2` `videobuf2-vmalloc` |
| `usb-serial` | `usbserial` `ftdi_sio` `ch341` `pl2303` `cp210x` |

Modules are built by subtree and collected by name (`find … -name <mod>.ko`)
rather than by hard-coded path, because `tveeprom` and `tuner` have moved
between kernel releases. `dvb-core` and `v4l2-common` are absent because their
configs are `=y`: a built-in symbol is linked into the kernel image, not
emitted as a `.ko`, so there is nothing to collect.
`scripts/verify-module-list.sh` asserts each
manifest's `DRIVER_LOAD_ORDER` is a subset of its `DRIVER_MODULES` and that the
enabled manifests agree on every `CONFIG_*` value.

## Requirements

- x86_64 QNAP NAS on QTS 5.2.x with a matching kernel.
- Container Station / Docker CLI on the NAS.
- ~10 GB free for the GPL source tree plus build artifacts.
- Internet access (SourceForge for the GPL source, plus firmware files).

## Quick start

Run these **on the NAS** (or any Docker host — the build is fully offline after
the download).

```bash
# 1. Seed .env first — the container sources it, so it must be in the
#    build context. The paths must be container-absolute, and DRIVERS
#    selects the families to build.
cp .env.example .env
# .env.example already sets: DRIVERS="dvb usb-serial"

# 2. Build the builder image.
docker build -f Dockerfile -t qnap-driver-builder .

# 3. Run the build. Mount src/ to cache the kernel tree and
#    modules/ to collect the .ko files.
docker run --rm --user root \
    -v "$PWD/src:/build/src" \
    -v "$PWD/modules:/modules-out" \
    -v "$PWD/logs:/build/logs" \
    qnap-driver-builder
```

First run downloads and extracts the GPL source (~30–90 min of
`make -j$(nproc)` after that). Later runs reuse `src/`.

### Install the modules and firmware

```bash
# Modules must land in extra/ for the running kernel.
sudo mkdir -p /lib/modules/$(uname -r)/extra
sudo cp modules/*.ko /lib/modules/$(uname -r)/extra/
sudo depmod -a "$(uname -r)"

# Firmware for the Si2168 demod — not shipped here, see below.
sudo cp dvb-demod-si2168-*.fw /lib/firmware/

# Load and verify. modprobe resolves the dependency order via depmod
# (module names use underscores: em28xx_dvb, not em28xx-dvb).
sudo modprobe em28xx_dvb
ls /dev/dvb           # adapter0, adapter1, ...
dmesg | tail -30 | grep -E 'em28xx|si2168|si2157'
```

The boot loader, `scripts/load-modules.sh`, does the install half of this on
every boot (see *Surviving reboots*). Once a USB-TTL cable is attached,
`ls /dev/ttyUSB0` is what the `usb-serial` family adds — `dmesg` names which
chip bound.

## Firmware

The firmware is **not** in this repository. The Si2168-B40 demod in the dualHD
typically wants one of:

```
dvb-demod-si2168-b40-01.fw
dvb-demod-si2168-02.fw
dvb-demod-si2168-d60-01.fw
```

Get whichever `dmesg` asks for from
[OpenELEC/dvb-firmware](https://github.com/OpenELEC/dvb-firmware) or the
[linuxtv firmware archive](http://palosaari.fi/linux/v4l-dvb/firmware/Si2168/),
drop it in `/lib/firmware/`, and reload the driver (or replug the stick).

## Surviving reboots and QTS updates

Two things QTS undoes for you:

- **`/lib/modules/<version>/extra` does not survive a reboot.** Re-install the
  modules and reload them at startup. QTS has no module autoload for custom
  drivers, so `scripts/load-modules.sh` runs from the boot path. It reinstalls
  `modules/*.ko`, syncs `firmware/*.fw` into `/lib/firmware`, and `insmod`s
  everything in each driver's declared load order, logging to
  `logs/module-boot.log`.

  Run **`scripts/qnap-install.sh`** once on the NAS to wire that up; it is
  idempotent, and re-running it is the repair step after a QTS update that
  loses the boot path. It installs an `/etc/rcS.d` boot hook, a 5-minute
  watchdog cron, and a flash `autorun.sh`, so no single QTS update can stop
  the modules loading. A crontab or Control Panel *Startup* entry pointing at
  `scripts/load-modules.sh` also works if you prefer to wire it by hand.
- **A QTS firmware update can change the kernel version** and wipe firmware.
  Custom modules are kernel-version-locked: load an old `.ko` on a new kernel
  and you get `Invalid module format`. After a major QTS update, set `QNAP_VER`
  in `.env` to the new version, rebuild, and reinstall.

The loader loads once at boot; the watchdog installed alongside it notices a
tuner that drops off afterwards. Both, and the three layers `qnap-install.sh`
wires up, are described in
[`docs/01-boot-and-persistence.md`](docs/01-boot-and-persistence.md).

## Feeding Tvheadend

To pass the adapters into a Tvheadend container:

```yaml
services:
  tvheadend:
    devices:
      - /dev/dvb:/dev/dvb
    privileged: true
```

Then scan DVB-T/T2 networks in the Tvheadend UI. The recording/transcode side of
that stack is a separate project — see below. The full set of expectations the
container places on this host (a `/dev/dvb` with at least one `frontend*` node,
em28xx bind timing, why `privileged: true` is needed) is written up in
[`docs/02-dvb-host-contract.md`](docs/02-dvb-host-contract.md).

## Adding a driver family

A family is one file in `drivers/` plus one word in `.env`. The contract, the
conventions and a worked example are in
[`docs/05-adding-a-driver.md`](docs/05-adding-a-driver.md).

## Where this fits

This repository is the driver half of a small home PVR setup — it exists so the
rest of that setup has a `/dev/dvb` to record from. The other halves are
separate projects, and neither is needed to use this one: the modules are
useful to any QTS host that wants a DVB adapter.

| Project | Role |
|---|---|
| QNAP PVR stack | Containerised Tvheadend + Jellyfin + comskip + transcode services that record from `/dev/dvb` and post-process to MP4. |
| CuBox transcode fleet | Two SolidRun CuBox i4Pro offline batch transcode appliances, kept off the NAS so long jobs do not compete with recording. |

## Troubleshooting

**`firmware file 'dvb-demod-si2168-*.fw' not found`** — copy the requested file
to `/lib/firmware/` and reload the driver.

**Build fails with `Module.symvers` errors** — a module is being built before the
one it depends on. Build the dependency subtrees (`media/dvb-core`,
`media/dvb-frontends`, `media/tuners`, `media/common`) ahead of the top-level
em28xx modules by reordering `DRIVER_DIRS` in the driver's manifest.

**Modules do not load / `Invalid module format`** — the `.ko` was built for a
different kernel. Check `uname -r` against `KERNEL_VER`/`QNAP_VER` in `.env`.

**Nothing appears in `/dev/dvb`** — check `dmesg` for the firmware request
first; the Si2168 will not register an adapter without firmware.

**`scan no data, failed` in Tvheadend** — firmware loaded (`dmesg | grep si2168`),
antenna/cable connected, and the scan preset matching your transmitter/region.

## License

Build scripts and Dockerfile are provided as-is. The QNAP GPL kernel source and
the Linux kernel modules remain under their own licenses (GPL v2).

## Acknowledgements

- [mammo0/qnap-qts-toolchain](https://github.com/mammo0/qnap-qts-toolchain) — the QNAP cross-toolchain image.
- QNAP — for publishing the GPL kernel source.
- LinuxTV / V4L-DVB — for the drivers.
