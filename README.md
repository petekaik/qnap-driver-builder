# QNAP DVB Module Builder

Docker-based kernel module builder for QNAP TS-X51 (and compatible x86_64 QNAP NAS devices) that compiles out-of-tree DVB/USB-media drivers for use on the host system.

This project was created to enable Hauppauge WinTV-dualHD DVB-T/T2 USB tuners on QNAP NAS devices whose stock kernel does not ship DVB drivers (e.g. QTS 5.2.x with kernel `5.10.60-qnap`).

## What it builds

The builder produces the kernel modules required for the Hauppauge WinTV-dualHD (USB ID `2040:8265`) and other em28xx / Si2168 / Si2157 based DVB devices:

- `dvb-usb.ko`
- `em28xx.ko`, `em28xx-dvb.ko`, `em28xx-v4l2.ko`, `em28xx-rc.ko`
- `si2168.ko`
- `si2157.ko`
- `tveeprom.ko`
- `tuner.ko`
- `videobuf2-common.ko`, `videobuf2-memops.ko`, `videobuf2-v4l2.ko`, `videobuf2-vmalloc.ko`

Plus the dependency modules pulled in by the kernel build system.

## Requirements

- A QNAP x86_64 NAS running QTS 5.2.x (kernel 5.10) — other versions may work if the GPL kernel source matches your running kernel.
- Container Station / Docker CLI on the QNAP host.
- Sufficient disk space in `/path/to/qnap-driver-builder` (or wherever you clone this repo): the GPL kernel source is ~500 MB and the build tree can exceed 5 GB.
- Internet access to download the QNAP GPL kernel source from SourceForge and firmware files.

## Quick start

1. Clone this repository on the QNAP host:

   ```bash
   cd /path/to
   git clone https://github.com/petekaik/qnap-dvb.git QNAP
   cd QNAP/build
   ```

2. Review/edit `.env` to match your device/kernel version:

   ```bash
   cat .env
   ```

   Defaults:
   - `QNAP_DEVICE=TS-X51`
   - `QNAP_VER=5.2.3.20250218`
   - `KERNEL_VER=5.10`

   Find the exact QTS version on your NAS with:

   ```bash
   uname -r
   # and check QTS version in QTS Control Panel -> System -> Firmware version
   ```

3. Build the Docker image:

   ```bash
   docker build -t qnap-dvb-builder .
   ```

4. Run the builder:

   ```bash
   docker run --rm --user root      -v /path/to/qnap-driver-builder/build/src:/build/src      -v /path/to/qnap-driver-builder/modules:/modules-out:rw      -v /path/to/qnap-driver-builder/logs:/build/logs:rw      qnap-dvb-builder
   ```

   The first run downloads the QNAP GPL kernel source and builds the modules. Subsequent runs reuse the cached kernel source.

5. Install the modules on the host:

   ```bash
   sudo mkdir -p /lib/modules/$(uname -r)/extra
   sudo cp /path/to/qnap-driver-builder/modules/*.ko /lib/modules/$(uname -r)/extra/
   sudo depmod -a $(uname -r)
   ```

6. Install the required firmware files:

   ```bash
   sudo cp /path/to/qnap-driver-builder/firmware/dvb-demod-si2168-02.fw /lib/firmware/
   sudo cp /path/to/qnap-driver-builder/firmware/dvb-demod-si2168-b40-01.fw /lib/firmware/
   sudo cp /path/to/qnap-driver-builder/firmware/dvb-demod-si2168-d60-01.fw /lib/firmware/
   ```

7. Load the drivers and verify the adapter:

   ```bash
   sudo modprobe em28xx_dvb
   ls /dev/dvb
   # should show adapter0, adapter1, etc.
   dmesg | tail -30 | grep -E 'em28xx|si2168|si2157'
   ```

## Firmware

The firmware files are **not included** in this repository. They are downloaded by the firmware helper scripts (see `firmware/`) or manually from the upstream firmware repositories:

- [OpenELEC/dvb-firmware](https://github.com/OpenELEC/dvb-firmware)
- [palosaari.fi linuxtv firmware archive](http://palosaari.fi/linux/v4l-dvb/firmware/Si2168/)

The Si2168-B40 demodulator used by the Hauppauge dualHD typically requires `dvb-demod-si2168-02.fw` or `dvb-demod-si2168-b40-01.fw`. Check `dmesg` after loading the driver to see which file the kernel requests.

## Project layout

```
QNAP/
├── build/                    # Docker builder source
│   ├── Dockerfile
│   ├── 0_prepare.sh          # generates .env
│   ├── build_env.sh          # build helpers and patch framework
│   ├── 2_build_dvb.sh        # main build script
│   ├── docker_entrypoint.sh
│   ├── apply_patches.py      # enables DVB/media kernel configs
│   ├── .env                  # build-time environment (per-host)
│   └── .dockerignore
├── firmware/                 # downloaded firmware files (not in git)
├── modules/                  # built .ko modules (not in git)
├── logs/                     # build logs (not in git)
└── README.md                 # this file
```

## Making it work with Tvheadend / Docker

To pass the DVB adapters into a Tvheadend container, add to the Tvheadend service in your `compose.yml`:

```yaml
services:
  tvheadend:
    devices:
      - /dev/dvb:/dev/dvb
    privileged: true
    environment:
      - PUID=0
      - PGID=0
```

Then recreate the container:

```bash
docker compose up -d --force-recreate tvheadend
```

Inside the container you should see `/dev/dvb/adapter0` and `/dev/dvb/adapter1`. Add DVB-T/T2 networks in the Tvheadend Web UI and run a channel scan.

## Adding support for other tuners

Edit `2_build_dvb.sh` and add the module paths to `MODULES_LIST`, then rebuild. You may also need to add the relevant `CONFIG_*` entries in `apply_patches.py` if they are not already enabled.

## Troubleshooting

### `firmware file 'dvb-demod-si2168-02.fw' not found`
The Si2168 demodulator needs firmware. Copy the requested file to `/lib/firmware/` and reload the driver (or unplug/replug the USB tuner).

### `scan no data, failed` in Tvheadend
- Verify the requested firmware loaded (`dmesg | grep si2168`).
- Check antenna/cable connection.
- Confirm the scan preset matches your region (DVB-T/T2 frequencies vary by transmitter).
- Try a manual mux frequency from your local broadcaster.

### Build fails with `Module.symvers` errors
This happens when a module depends on symbols from another module that was not built first. Re-run the builder; the script now builds dependency subtrees (`drivers/media/common`, `drivers/media/tuners`, `drivers/media/dvb-frontends`) before the top-level em28xx modules and merges `Module.symvers` between stages.

## License

The build scripts and Dockerfile are provided as-is for personal use. The QNAP GPL kernel source and Linux kernel modules are subject to their respective licenses (GPL v2).

## Acknowledgements

- [mammo0/qnap-qts-toolchain](https://github.com/mammo0/qnap-qts-toolchain) for the QNAP cross-toolchain Docker image.
- QNAP for publishing the GPL kernel source.
- LinuxTV / V4L-DVB project for the DVB drivers.
