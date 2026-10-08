# 02 — DVB host contract

What this project must deliver to whatever consumes the tuner, and what the
consumer is entitled to assume. The consumer today is a containerised PVR stack
(TVHeadend, fronted by Jellyfin); the contract is written so any other recorder
can be substituted.

## The interface: `/dev/dvb`

Everything between host and consumer goes through the DVB device nodes. There is
no IPC, no socket, no shared library — the consumer bind-mounts the device tree:

```yaml
devices:
  - /dev/dvb:/dev/dvb
privileged: true
```

The contract is:

| Requirement | Meaning |
|---|---|
| `/dev/dvb/` exists | The modules loaded and at least one adapter registered |
| At least one `frontend*` node under `adapterN/` | The adapter is actually usable — a registered adapter with no frontend cannot tune |
| Nodes stay stable across a reboot | Anything holding an open handle across a restart gets a different `adapterN` otherwise |
| Firmware present in `/lib/firmware` | The Si2168 registers no adapter at all without `dvb-demod-si2168-*.fw` |
| Tuner binds within ~30 s of boot | The consumer's healthcheck gives up after 30 s |

`privileged: true` is required because a container needs it to open the
`/dev/dvb` character devices on QTS. It is scoped to the single TVHeadend
service; the healthcheck itself only ever *reads* `/dev/dvb`, never application
config.

## The consumer's check

`qnap-pvr`'s `scripts/tvh-healthcheck.sh` is the executable form of this
contract, run as a Docker healthcheck. It polls for up to 30 s — "30 s is plenty
for em28xx binding" — and exits 0 only when `/dev/dvb` exists and a
`find /dev/dvb -maxdepth 2 -name 'frontend*'` matches. Otherwise it exits 1 and
Docker restarts the container.

That 30 s window is a real deadline, not a formality: it is the reason the
module load must complete inside container init. The `sleep 3` before `insmod`
in `scripts/load-modules.sh` exists to let USB enumeration finish first, and the
watchdog cron in [`01-boot-and-persistence.md`](01-boot-and-persistence.md)
Approach B is the only mechanism that would recover a tuner lost *after* that
window.

## What breaks the contract

| Symptom | Cause |
|---|---|
| `/dev/dvb` missing entirely | Modules not loaded — QTS wiped `extra/` on reboot, or the loader never ran |
| `/dev/dvb` present, no `frontend*` | Firmware missing; check `dmesg` for the `dvb-demod-si2168-*.fw` request |
| Adapter appears, scan finds nothing | Aerial not connected, or the scan preset does not match the transmitter — not a host fault |
| Worked, then stopped after a QTS update | Kernel version moved; the `.ko` files are stale (`Invalid module format` in `dmesg`) |
| Healthcheck flaps on boot | The module load is finishing after the 30 s window |

## Out of scope here

Tuner configuration, muxes, channel scanning, EPG and recording all live in the
consumer — in the PVR stack, documented in that project's own
`docs/CONFIGURATION.md`. This project ends at "a working `/dev/dvb` exists".
