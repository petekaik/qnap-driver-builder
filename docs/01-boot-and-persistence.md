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

## Approach A — `scripts/load-dvb.sh` (implemented)

The loader in this repo. On every boot it:

1. re-installs every `modules/*.ko` into `/lib/modules/$(uname -r)/extra` and
   reruns `depmod -a`, because QTS wiped the directory;
2. refreshes any `firmware/*.fw` that is missing from `/lib/firmware` or older
   than the copy in the repo;
3. sleeps 3 s so USB enumeration has a chance to finish, then `insmod`s each
   module **in dependency order** — tuner before demod before bridge:
   `videobuf2-*` → `tuner` → `tveeprom` → `si2157` → `si2168` → `dvb-usb` →
   `em28xx` → `em28xx-dvb`;
4. logs everything to `logs/dvb-boot.log` and finishes by listing `/dev/dvb`.

It derives the project root from its own location (`dirname "$0"/..`), so it
works from wherever the repo is cloned, and it is idempotent — a module already
in `lsmod` is reported, not reloaded.

`insmod` is used rather than `modprobe` because the modules are outside the
`depmod` search path until step 1 has run; that is why the order is written out
by hand. If you add a module, add it to the loop *and* to `MODULES_LIST` in
`2_build_dvb.sh`, then run `scripts/verify-module-list.sh`.

### Installing it

Startup cron, in `/etc/config/crontab`:

```
@reboot root /path/to/qnap-dvb/scripts/load-dvb.sh
```

then `/etc/init.d/crond.sh restart`. Alternatively QTS Control Panel → System →
Hardware → Schedule → *Startup*. Verify on the next boot with:

```sh
lsmod | grep em28xx
ls /dev/dvb
dmesg | tail -20 | grep -E 'em28xx|si2168|si2157'
```

## Approach B — QNAP `autorun.sh` + `/etc/rcS.d/` + watchdog (design sketch)

An alternative recorded during the `pvr-tvhd` investigation, **not implemented in
this repo**:

- `autorun.sh` on a data volume is QNAP's supported hook that runs at boot;
- a `/etc/rcS.d/S98dvb-loader` init script gives the load a place in the boot
  ordering rather than racing USB enumeration;
- a watchdog cron re-loads the modules if the adapter disappears later (a USB
  re-enumeration after a reset, for instance).

It exists here only as a sketch, so treat the `scripts/load-dvb.sh` route as
the supported one. The advantage it would add over Approach A is the watchdog —
Approach A loads once and does not notice a tuner that drops off afterwards.

## Rebuilding after a QTS update

```sh
uname -r                      # the running kernel, e.g. 5.10.60-qnap
```

Compare against `KERNEL_VER` / `QNAP_VER` in `.env`, point `QNAP_VER` at the new
QTS release, and rebuild. The builder fetches the GPL source matching
`QNAP_VER`, so the two must agree or the modules are built against the wrong
kernel and will not load.

After rebuilding: copy the new `modules/*.ko` over the old ones, reinstall the
firmware, and reload. `scripts/load-dvb.sh` does the install half of this on the
next boot.

## Verifying

There is no automated test for this: the honest check is a reboot of the NAS
followed by `lsmod | grep em28xx` and `ls /dev/dvb`. Everything up to that point
— that the loader and the builder agree on which modules exist — is covered by
`scripts/verify-module-list.sh`.
