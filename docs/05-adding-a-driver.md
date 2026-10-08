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
2. Add `<name>` to `DRIVERS=` in **`.env.example`** as well as `.env`, then
   rebuild the image so it carries the new value:
   `docker build -f Dockerfile -t qnap-driver-builder .`. `.env` is copied in
   at `docker build` time and is not mounted on the `run` line, so editing it
   alone leaves an already-built image still running the old set. The verifier
   and CLAUDE.md's invariant key on `.env.example`, so a name only in `.env` is
   checked for well-formedness but its `CONFIG_*` values are never merged.
3. Run `scripts/verify-module-list.sh`.
4. Build with `DRY_RUN=1` first — it prints the merged config, the `make`
   commands and the `find` commands without downloading anything. The loader
   has its own `DRY_RUN=1`, which prints each driver's declared
   `DRIVER_LOAD_ORDER` with no built `.ko` files, so the order can be checked
   without a build. The loader redirects all its output to
   `logs/module-boot.log`, so that run is silent on the terminal — read the log
   to see the order.

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
cable; `lsusb -t` (or `dmesg`) reports which one bound.

## What the contract does not cover

The manifest is data: config entries, dirs, modules, load order, firmware. A
family that needs *logic* the contract cannot express would need a hook in the
builder. No family needs one today, so there is none — a hook that is never
called is a hook that is never tested. If a third family arrives that cannot be
described as data, add the hook then, and give it a per-driver lifetime.

## Verifying

`scripts/verify-module-list.sh` checks every manifest is well-formed, POSIX-
parseable, that `DRIVER_LOAD_ORDER ⊆ DRIVER_MODULES`, that no two drivers in
`.env.example`'s `DRIVERS=` set disagree about a `CONFIG_*` value, and that
every name in that set exists. It warns about modules that are built but never
loaded.
