# 01 — Boot and persistence

QTS actively undoes this project's work in two ways. Both are handled here.

## What QTS breaks

1. **`/lib/modules/$(uname -r)/extra` does not survive a reboot.** QTS rebuilds
   that tree at boot, so the `.ko` files vanish. QTS also has no autoload
   mechanism for out-of-tree modules — `modules-load.d`, `modprobe.d` and
   `initramfs` are not wired up the way a stock distro wires them.
2. **A QTS firmware update can change the kernel version**, and wipes
   `/lib/firmware` along the way. Custom modules are kernel-version-locked: an
   old `.ko` on a new kernel refuses to load with `Invalid module format`.

So persistence needs two things: reinstall-and-reload at every boot, and a
rebuild whenever the kernel version moves.

## Approach A — `scripts/load-modules.sh` (implemented)

The loader in this repo. On every boot it:

1. re-installs every `modules/*.ko` into `/lib/modules/$(uname -r)/extra` and
   reruns `depmod -a`, because QTS wiped the directory;
2. refreshes any `firmware/*.fw` that is missing from `/lib/firmware` or older
   than the copy in the repo;
3. sleeps 3 s so USB enumeration has a chance to finish, then `insmod`s each
   module; modules load in each driver's declared `DRIVER_LOAD_ORDER`; the DVB
   chain is still `videobuf2-*` → `tuner` → `tveeprom` → `si2157` → `si2168` →
   `dvb-usb` → `em28xx` → `em28xx-rc` → `em28xx-dvb`, and USB-serial is
   `usbserial` → chip driver;
4. logs everything to `logs/module-boot.log` and finishes by listing `/dev/dvb`
   and `/dev/ttyUSB*`.

It derives the project root from its own location (`dirname "$0"/..`), so it
works from wherever the repo is cloned, and it is idempotent — a module already
in `lsmod` is reported, not reloaded.

`insmod` is used rather than `modprobe` because the modules are outside the
`depmod` search path until step 1 has run; that is why the order is written out
by hand. If you add a module, add it to its driver's manifest (`DRIVER_MODULES`
and, if it must be loaded, `DRIVER_LOAD_ORDER`), then run
`scripts/verify-module-list.sh`.

### Installing it

`scripts/qnap-install.sh` wires the loader into the boot path. Run it once on
the NAS, from the checkout's root:

```sh
cd /path/to/qnap-driver-builder    # wherever the repo lives on the NAS
scripts/qnap-install.sh
```

It derives every path from its own location, so the checkout can live anywhere.

It is idempotent, and re-running it is the repair step after any QTS update that
loses the boot path. It installs three layers, least durable first, so a
firmware update has to destroy all three to stop the modules loading:

| Layer | Path | Survives |
|---|---|---|
| boot ordering | `/etc/init.d/dvb-loader.sh` → `scripts/load-modules.sh`, and `/etc/rcS.d/S98dvb-loader` → that | normal reboots; `S98` runs before QNAP's own `S99` services |
| watchdog | `/etc/config/user_cmd/dvb-watchdog.cron`, every 5 minutes | firmware updates that wipe `/etc/rcS.d` or `/etc/init.d` |
| flash autorun | `/tmp/config/autorun.sh` on the boot flash, plus `Misc Autorun=TRUE` via `setcfg` | firmware updates, because it lives on the flash partition |

The installed names say `dvb` for history: they are what the NAS already has,
and renaming a live boot path to gain tidiness risks a dangling symlink and a
silent loss of load-on-boot. What they point at is family-neutral.

QTS Control Panel → System → Hardware → Schedule → *Startup* is an alternative
to the rcS link. A crontab still pointing at `scripts/load-dvb.sh` keeps working
through the shim, which `exec`s the new loader; delete the shim once every NAS
has been repointed.

Verify on the next boot with:

```sh
lsmod | grep -E 'em28xx|ftdi_sio'
ls /dev/dvb /dev/ttyUSB*
tail -20 logs/module-boot.log
```

## Approach B — rcS + `autorun.sh` + watchdog (implemented)

Approach A alone loads once at boot and does not notice a device that drops off
afterwards — a USB re-enumeration after a reset, or a QTS update that wipes the
boot path. Approach B adds recovery and is what `qnap-install.sh` installs:

- `/etc/rcS.d/S98dvb-loader` gives the load a place in the boot ordering rather
  than racing USB enumeration;
- `scripts/dvb-watchdog.sh` runs every 5 minutes, exits silently while the health
  path exists, and otherwise re-runs the installer and then the loader, so a QTS
  update that wipes the boot path heals without a reboot;
- `autorun.sh` on the flash partition is the most durable hook, and the one a QTS
  firmware update is least likely to remove.

The loader's exit codes are the watchdog's signal: `0` loaded, `1` nothing to
install, `2` at least one `insmod` failed. A loader that reported success after
loading nothing would make the watchdog worthless, so those codes are a
contract, not decoration.

## Rebuilding after a QTS update

```sh
uname -r                      # the running kernel, e.g. 5.10.60-qnap
```

Compare against `KERNEL_VER` / `QNAP_VER` in `.env`, point `QNAP_VER` at the new
QTS release, and rebuild. The builder fetches the GPL source matching
`QNAP_VER`, so the two must agree or the modules are built against the wrong
kernel and will not load.

After rebuilding: copy the new `modules/*.ko` over the old ones, reinstall the
firmware, and reload. `scripts/load-modules.sh` does the install half of this on
the next boot.

## Verifying

There is no automated test for this: the honest check is a reboot of the NAS
followed by `lsmod | grep em28xx` and `ls /dev/dvb`. Everything up to that point
— that the loader and the builder agree on which modules exist — is covered by
`scripts/verify-module-list.sh`.
