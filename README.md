# QNAP DVB Module Builder

Builds the DVB / USB-media kernel modules that QNAP's stock QTS kernel does not
ship, so a **Hauppauge WinTV-dualHD** (USB `2040:8265`) DVB-T/T2 stick works on
x86_64 QNAP NAS hardware.

The modules are compiled **in a Docker container** against QNAP's published GPL
kernel source — nothing is built natively on the NAS, which is why this works at
all on a locked-down QTS install.

| | |
|---|---|
| Target device | TS-X51 series (TS-251 / 251+ / 451 / 651 / 851, Celeron J1900, x86_64) |
| Target OS | QTS 5.2.x, kernel `5.10` (`5.10.60-qnap`) |
| Tuner | Hauppauge WinTV-dualHD, USB ID `2040:8265` (em28xx bridge + Si2168 demod + Si2157 tuner) |
| Toolchain | [`mammo0/qnap-qts-toolchain:vivid`](https://github.com/mammo0/qnap-qts-toolchain) |

## Project layout

```
.
├── Dockerfile.dvb            # builder image (toolchain + build user uid/gid 1000)
├── docker_entrypoint.sh      # prints toolchain info, runs 2_build_dvb.sh
├── 0_prepare.sh              # generates .env (device, QTS version, paths)
├── build_env.sh              # sources .env, provides patch/enter/leave helpers
├── 2_build_dvb.sh            # the build: download GPL source, patch config, build modules
├── apply_patches.py          # enables the 33 DVB/USB-media CONFIG_* entries
├── scripts/
│   ├── load-dvb.sh           # boot loader: reinstall + insmod modules, sync firmware
│   ├── verify-module-list.sh # asserts load-dvb.sh and MODULES_LIST agree
│   └── check-secrets.sh      # keeps credentials/IPs/host paths out of commits
├── docs/
│   ├── 01-boot-and-persistence.md  # keeping modules loaded across reboots and QTS updates
│   └── 02-host-contract.md         # what a consumer (TVHeadend) needs from the host
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
   `QNAP_KERNEL_CONFIG_FILE` and friends. **All paths in `.env` must be
   container-absolute** (`/build/...`) — see Quick start.
2. `2_build_dvb.sh` downloads `GPL_QTS-<QNAP_VER>_Kernel.tar.gz` from QNAP's
   SourceForge GPL archive into `$SRC_DIR` (split-file fallback included), then
   copies the device's reference config to `$KERNEL_DIR/.config`.
3. `apply_patches.py` turns on the 33 DVB / V4L2 / USB-media `CONFIG_*` entries,
   then `make prepare` + `modules_prepare` runs, then each subtree in
   `MODULE_DIRS` is built and the modules named in `MODULES_LIST` are collected
   into `/modules-out/`.
4. Mount `/modules-out` to a host directory to collect the modules. The
   `src/` mount caches the several-GB kernel tree between runs.

Modules produced (`MODULES_LIST` in `2_build_dvb.sh`):

```
em28xx          em28xx-v4l2      em28xx-dvb     dvb-usb
si2168          si2157          tuner          tveeprom
dvb-core        v4l2-common
videobuf2-common  videobuf2-memops  videobuf2-v4l2  videobuf2-vmalloc
```

Modules are built by subtree and collected by name (`find … -name <mod>.ko`)
rather than by hard-coded path, because `tveeprom` and `tuner` have moved
between kernel releases. `scripts/verify-module-list.sh` asserts this list
stays in step with what the boot loader loads.

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
#    build context. The paths must be container-absolute.
cp .env.example .env

# 2. Build the builder image.
docker build -f Dockerfile.dvb -t qnap-driver-builder .

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
  drivers, so `scripts/load-dvb.sh` runs from a startup cron entry
  (`@reboot` in `/etc/config/crontab`, then `/etc/init.d/crond.sh restart`) or
  from Control Panel → System → Hardware → Schedule → *Startup*. It reinstalls
  `modules/*.ko`, syncs `firmware/*.fw` into `/lib/firmware`, and `insmod`s
  everything in dependency order, logging to `logs/dvb-boot.log`.
- **A QTS firmware update can change the kernel version** and wipe firmware.
  Custom modules are kernel-version-locked: load an old `.ko` on a new kernel
  and you get `Invalid module format`. After a major QTS update, set `QNAP_VER`
  in `.env` to the new version, rebuild, and reinstall.

`scripts/load-dvb.sh` is one of two ways to keep the tuner alive across a
reboot — the other is a QNAP `autorun.sh` + `/etc/rcS.d/` loader with a watchdog
cron. Both are described in
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
[`docs/02-host-contract.md`](docs/02-host-contract.md).

## Adding support for other tuners

The pipeline is not specific to the dualHD. To build for a different
USB DVB device:

1. Add its modules to `MODULES_LIST` in `2_build_dvb.sh` (by basename), and the
   subtree that produces them to `MODULE_DIRS`.
2. Add the `CONFIG_*` entries it needs to `apply_patches.py`. A module whose
   dependency is set to `=m` but never built fails with unresolved
   `Module.symvers` symbols, so check the entries already there for the pattern.
3. Add the modules to the load order in `scripts/load-dvb.sh` (tuner before
   demod before bridge).
4. Run `scripts/verify-module-list.sh` — it fails if the loader and the builder
   disagree.
5. Check `dmesg` after the first load for the firmware filename the kernel
   requests, and put that file in `firmware/`.

Different QNAP models also need `QNAP_DEVICE`, `QNAP_VER` and
`QNAP_KERNEL_CONFIG_FILE` in `.env` pointed at the matching device/version —
pick the config from `kernel_cfg/` inside the downloaded GPL source.

## Related projects

| Project | Role |
|---|---|
| [`petekaik/qnap-driver-builder`](https://github.com/petekaik/qnap-driver-builder) | **This repo's published remote.** `<projects-dir>/<retired-working-copy>` was the working copy that carried the `apply_patches.py` and `load-dvb.sh` fixes; those are merged in here now and that directory is retired. |
| `<projects-dir>/qnap-pvr` | The consumer: containerised Tvheadend + Jellyfin + comskip + transcode PVR stack that records from `/dev/dvb` and post-processes to MP4. |
| `<projects-dir>/pvr-cubox-fleet` | The transcode fleet: two SolidRun CuBox i4Pro offline batch transcode appliances. Their **serial console** (MicroUSB UART, 115200 8N1; netconsole as fallback when no USB-TTL adapter is attached) is the out-of-band route for monitoring and remediating a box that will not come up. |
| `<projects-dir>/<transcoder-working-copy>` | Transcode container scripts staged out of the PVR stack. |

## Troubleshooting

**`firmware file 'dvb-demod-si2168-*.fw' not found`** — copy the requested file
to `/lib/firmware/` and reload the driver.

**Build fails with `Module.symvers` errors** — a module depends on symbols from a
module built later. Build dependency subtrees (`media/common`, `media/tuners`,
`media/dvb-frontends`) before the top-level em28xx modules. The published
sibling merges `Module.symvers` between stages.

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
