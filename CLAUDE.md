# CLAUDE.md — QNAP Driver Builder

Read this first. It records what this repo is, how the build actually flows, the
invariants that must not be broken, and the known gaps in this working copy.

## Project summary

Cross-builds the kernel modules QNAP's stock QTS kernel omits, so hardware QTS
ignores works on an **x86_64 QNAP NAS (TS-X51 series, QTS 5.2.x, kernel
5.10.60-qnap)**. Two driver families are carried: **dvb** — a **Hauppauge
WinTV-dualHD** (USB `2040:8265`) DVB-T/T2 stick — and **usb-serial**, so a
USB-TTL cable enumerates as `/dev/ttyUSB0`.

Everything compiles in a Docker container against QNAP's published GPL kernel
source (`mammo0/qnap-qts-toolchain:vivid`). The NAS only ever receives finished
`.ko` files. For DVB the chip chain is em28xx (USB bridge) → Si2168 (demod) →
Si2157 (tuner); each link needs its own module and the Si2168 needs firmware.

This repo is **not** the PVR stack — it only produces drivers. The stack that
records from them is `<projects-dir>/qnap-pvr`; the transcode fleet is
`<projects-dir>/pvr-cubox-fleet`. See *Related projects* at the bottom.

## Pipeline — how a build actually runs

```
Dockerfile                  image: toolchain + build user uid/gid 1000; repo ADD --chown to /build
  └─ docker_entrypoint.sh   prints gcc/ld, then execs ./2_build_modules.sh
       ├─ build_env.sh      sources .env → SRC_DIR, KERNEL_DIR, QNAP_KERNEL_CONFIG_FILE, DRIVERS …
       ├─ drivers/*/manifest.sh   one file per driver family, sourced by the builder and the loader
       └─ 2_build_modules.sh      scripts/lib-drivers.sh → merge each manifest's DRIVER_CONFIGS
                                  (apply_configs.py) → download GPL source → make prepare
                                  → modules_prepare → build DRIVER_DIRS → collect DRIVER_MODULES
                                  by name → /modules-out/
```

`0_prepare.sh` writes `.env` by expanding `$TMP_BASE_DIR`, which it derives from
its own location. Run it on the host and you get host paths; run it from
`/build` and you get container paths. In practice `.env` is seeded from
`.env.example` (container paths) and `0_prepare.sh` is not used.

Each family's manifest is the single source of truth for what that family
builds: `DRIVER_MODULES` (basenames to collect), `DRIVER_DIRS` (the kernel
subtrees that produce them) and `DRIVER_LOAD_ORDER` (the `insmod` order). The
`DRIVERS=` list in `.env` names which manifests are enabled. Modules are
collected with `find … -name <mod>.ko` rather than by hard-coded path, because
`tveeprom` and `tuner` have moved between kernel releases.

**The repo is a git repo** (remote
`git@github.com:petekaik/qnap-driver-builder.git`, which matches the on-disk
directory name). It inherited that history from `<projects-dir>/<retired-working-copy>`,
which was absorbed and retired. Layout: builder at the repo root, operational
scripts in `scripts/`, prose in `docs/`.

## Invariants — do not break these

1. **Modules are kernel-version-locked.** `QNAP_VER` in `.env` must match the
   QTS release the NAS runs, so the GPL source matches the running kernel. A
   mismatch loads as `Invalid module format`. After a QTS update: bump
   `QNAP_VER`, rebuild, reinstall.
2. **`.env` paths must be container-absolute** (`/build/...`). `build_env.sh`
   sources `.env` and `2_build_modules.sh` does `cp "$QNAP_KERNEL_CONFIG_FILE"`. A
   host path silently produces a build that cannot find the kernel tree.
3. **Do not exclude `.env` in `.dockerignore`.** The container has no other way
   to learn `/build` paths — the entrypoint only accepts `build`/`clean` and
   will not run `0_prepare.sh`.
4. **`CONFIG_MEDIA_SUPPORT`, `CONFIG_VIDEO_DEV`, `CONFIG_DVB_CORE`,
   `CONFIG_USB` must be `=y`, not `=m`.** They are dependencies of the modules
   being built; if one is a module that is never built, the dependent module
   fails with unresolved `Module.symvers` symbols. The `dvb` manifest encodes
   the `y`/`m` split deliberately — do not "tidy" those values.
5. **`DRIVER_LOAD_ORDER` must be a subset of `DRIVER_MODULES` in every manifest,
   and `DRIVERS=` in `.env.example` must name real manifests.**
   `scripts/verify-module-list.sh` asserts both.
6. **Keep the `pushd`/`popd` wrappers and the `exit()` override in
   `build_env.sh`.** They are what makes the sourced-environment cleanup work;
   removing them leaves the build user in the wrong directory.
7. **Order matters in the loader.** `insmod` must run a module after everything
   it depends on, so each manifest declares its order in `DRIVER_LOAD_ORDER`; the
   DVB chain is `videobuf2-*` → `tuner` → `tveeprom` → `si2157` → `si2168` →
   `dvb-usb` → `em28xx` → `em28xx-dvb`, and USB-serial is `usbserial` → chip
   driver. The modules are outside the `depmod` search path until the loader has
   installed them, so `modprobe` cannot resolve this for you — the declared order
   is load-bearing.
8. **Nothing sensitive is publishable.** Credentials, usernames, passwords, IP
   addresses and machine-specific paths live in a gitignored `.env`; the public
   `.env.example` carries anonymised placeholders only, and scripts hardcode
   nothing. `scripts/check-secrets.sh` enforces this and is installed as a
   pre-commit hook — never bypass it with `git commit --no-verify`.

## Fixes applied, and what is left

These were the gaps in the earlier snapshot. Items 1–4 and 6 are fixed here and
recorded because the fixes are easy to undo by accident.

| # | Was | Now |
|---|---|---|
| 1 | `QNAP_ARCHIVE` used but never set — the first run aborted on `tar -zxf ""` | Defined in `2_build_modules.sh` beside the other derived paths |
| 2 | `apply_config_patches` invoked a relative `scripts/config` from `$SRC_DIR`, so it always fell through to a two-config `sed` that set `=m` where invariant 4 needs `=y` | Replaced with one `apply_configs.py` call over the merged driver configs — absolute path, cwd-independent |
| 3 | No boot-persistence loader | `scripts/load-modules.sh` (manifest-driven; from the retired sibling), plus `docs/01-boot-and-persistence.md` |
| 4 | `MODULES_LIST` missing `tveeprom`, `tuner`, `videobuf2-*` | Each manifest lists its modules and load order; `scripts/verify-module-list.sh` guards it |
| 5 | `docker_entrypoint.sh` cannot run `0_prepare.sh` | **Still true, deliberately** — the entrypoint only `exec`s `build`/`clean` and otherwise hard-runs `2_build_modules.sh`, so `.env` must be present in the build context. See invariant 3. |
| 6 | Odd file modes (scripts `0711`, Dockerfile `0600`) | Normalised to `755` / `644` |

Remaining limitations:

- **No `--chmod` on `ADD`** in `Dockerfile`, which the retired sibling had.
  `docker_entrypoint.sh` already runs `chmod +x *.sh` at start-up, so it buys
  nothing, and `--chmod` needs a newer Docker than Container Station may ship.
- **`build_env.sh` has no guard on an unset `TMP_DIR`** — `_leave()` runs
  `rm -rf "$TMP_DIR"`. Harmless while it is empty (`rm -f`), but check callers
  before that variable ever gains a value.
- **The build has not been run end-to-end from this tree.** Everything verified
  here is syntax and internal consistency; the real proof is a build plus
  `ls /dev/dvb` on the NAS.

## Conventions

- Bash, `set -eo pipefail`, functions not classes. The builder scripts live at
  the repo root, numbered in execution order (`0_`, `2_`; `1_` is the implicit
  `docker build`). Everything operational goes in `scripts/`, everything prose
  in `docs/NN-name.md`.
- A new driver family is one file in `drivers/` plus one word in `.env`; never
  add a driver name to a script.
- The tests are plain `sh` scripts with no framework, in `scripts/`:
  `verify-module-list.sh` asserts every manifest's `DRIVER_LOAD_ORDER` is a
  subset of its `DRIVER_MODULES` and that the enabled manifests agree on every
  `CONFIG_*` value; `check-secrets.sh` asserts nothing sensitive is publishable.
  Add an assert to one of them rather than introducing a suite. The end-to-end
  "test" is a successful build plus `ls /dev/dvb` and a `dmesg` check on the NAS.
- Run `scripts/check-secrets.sh --install` once per clone to hook the check into
  `.git/hooks/pre-commit` (hooks are local, so this is not automatic). Run it by
  hand before publishing anything. When a legitimate placeholder trips it, mark
  the line with a trailing `secretscan:ignore` comment rather than loosening the
  pattern.
- The GPL source, `.ko` output, firmware and logs are host state under `src/`,
  `modules/`, `firmware/`, `logs/` — all gitignored, never committed.
- `.env` is gitignored and ships as `.env.example`; it must **not** be added to
  `.dockerignore` (invariant 3).
- Firmware is never vendored here; point at the upstream archives instead.
- Shell edits are syntax-checked with `bash -n`, Python with
  `python3 -m py_compile`, before committing.

## Related projects (`<projects-dir>/`)

| Path | Relationship |
|---|---|
| `<retired-working-copy>` (**deleted**) | Was the working copy that carried the `apply_patches.py` / `load-dvb.sh` fixes. Those are absorbed into **this repo**, which now inherits that history and the remote. Renamed to `<retired-working-copy>`, verified file-by-file against this repo's HEAD, then deleted. Do not resurrect it as a second builder. |
| `qnap-pvr` | Downstream consumer. Tvheadend + Jellyfin + comskip + transcode containers that record from `/dev/dvb` and post-process to MP4. This repo's output is what makes `/dev/dvb` exist for it. |
| `pvr-cubox-fleet` | Sibling fleet, not a consumer. Two CuBox i4Pro offline batch transcode appliances. Its **serial console** (MicroUSB UART 115200 8N1; netconsole fallback when no USB-TTL adapter) is the out-of-band monitoring/remediation path for a box that will not boot — see its `docs/05-troubleshooting.md` and `CLAUDE.md` item 18. |
| `<transcoder-working-copy>` | Transcode container scripts staged out of `qnap-pvr`. |
