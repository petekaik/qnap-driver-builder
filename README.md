1|# QNAP DVB Module Builder
2|
3|Docker-based kernel module builder for QNAP TS-X51 (and compatible x86_64 QNAP NAS devices) that compiles out-of-tree DVB/USB-media drivers for use on the host system.
4|
5|This project was created to enable Hauppauge WinTV-dualHD DVB-T/T2 USB tuners on QNAP NAS devices whose stock kernel does not ship DVB drivers (e.g. QTS 5.2.x with kernel `5.10.60-qnap`).
6|
7|## What it builds
8|
9|The builder produces the kernel modules required for the Hauppauge WinTV-dualHD (USB ID `2040:8265`) and other em28xx / Si2168 / Si2157 based DVB devices:
10|
11|- `dvb-usb.ko`
12|- `em28xx.ko`, `em28xx-dvb.ko`, `em28xx-v4l2.ko`, `em28xx-rc.ko`
13|- `si2168.ko`
14|- `si2157.ko`
15|- `tveeprom.ko`
16|- `tuner.ko`
17|- `videobuf2-common.ko`, `videobuf2-memops.ko`, `videobuf2-v4l2.ko`, `videobuf2-vmalloc.ko`
18|
19|Plus the dependency modules pulled in by the kernel build system.
20|
21|## Requirements
22|
23|- A QNAP x86_64 NAS running QTS 5.2.x (kernel 5.10) — other versions may work if the GPL kernel source matches your running kernel.
24|- Container Station / Docker CLI on the QNAP host.
25|- At least 10 GB of free disk space for the build tree and the downloaded GPL kernel source (~500 MB compressed, several GB when extracted).
26|- Internet access to download the QNAP GPL kernel source from SourceForge and firmware files.
27|
28|## Quick start
29|
1. Clone this repository on the QNAP host to a directory of your choice (for example under a persistent data volume):

   ```bash
   cd /path/to/your/projects
   git clone https://github.com/petekaik/qnap-dvb.git
   cd qnap-dvb/build
   ```
37|
38|2. Review/edit `.env` to match your device/kernel version:
39|
40|   ```bash
41|   cat .env
42|   ```
43|
44|   Defaults:
45|   - `QNAP_DEVICE=TS-X51`
46|   - `QNAP_VER=5.2.3.20250218`
47|   - `KERNEL_VER=5.10`
48|
49|   Find the exact QTS version on your NAS with:
50|
51|   ```bash
52|   uname -r
53|   # and check QTS version in QTS Control Panel -> System -> Firmware version
54|   ```
55|
56|3. Build the Docker image:
57|
58|   ```bash
59|   docker build -t qnap-dvb-builder .
60|   ```
61|
62|4. Run the builder:
63|
64|   ```bash
65|   docker run --rm --user root      -v /path/to/qnap-dvb/build/src:/build/src      -v /path/to/qnap-dvb/modules:/modules-out:rw      -v /path/to/qnap-dvb/logs:/build/logs:rw      qnap-dvb-builder
66|   ```
67|
68|   The first run downloads the QNAP GPL kernel source and builds the modules. Subsequent runs reuse the cached kernel source.
69|
70|5. Install the modules on the host:
71|
72|   ```bash
73|   sudo mkdir -p /lib/modules/$(uname -r)/extra
74|   sudo cp /path/to/qnap-dvb/modules/*.ko /lib/modules/$(uname -r)/extra/
75|   sudo depmod -a $(uname -r)
76|   ```
77|
78|6. Install the required firmware files:
79|
80|   ```bash
81|   sudo cp /path/to/qnap-dvb/firmware/dvb-demod-si2168-02.fw /lib/firmware/
82|   sudo cp /path/to/qnap-dvb/firmware/dvb-demod-si2168-b40-01.fw /lib/firmware/
83|   sudo cp /path/to/qnap-dvb/firmware/dvb-demod-si2168-d60-01.fw /lib/firmware/
84|   ```
85|
86|7. Load the drivers and verify the adapter:
87|
88|   ```bash
89|   sudo modprobe em28xx_dvb
90|   ls /dev/dvb
91|   # should show adapter0, adapter1, etc.
92|   dmesg | tail -30 | grep -E 'em28xx|si2168|si2157'
93|   ```
94|
95|## Firmware
96|
97|The firmware files are **not included** in this repository. They are downloaded by the firmware helper scripts (see `firmware/`) or manually from the upstream firmware repositories:
98|
99|- [OpenELEC/dvb-firmware](https://github.com/OpenELEC/dvb-firmware)
100|- [palosaari.fi linuxtv firmware archive](http://palosaari.fi/linux/v4l-dvb/firmware/Si2168/)
101|
102|The Si2168-B40 demodulator used by the Hauppauge dualHD typically requires `dvb-demod-si2168-02.fw` or `dvb-demod-si2168-b40-01.fw`. Check `dmesg` after loading the driver to see which file the kernel requests.
103|
104|## Project layout
105|
106|```
107|QNAP/
108|├── build/                    # Docker builder source
109|│   ├── Dockerfile
110|│   ├── 0_prepare.sh          # generates .env
111|│   ├── build_env.sh          # build helpers and patch framework
112|│   ├── 2_build_dvb.sh        # main build script
113|│   ├── docker_entrypoint.sh
114|│   ├── apply_patches.py      # enables DVB/media kernel configs
115|│   ├── .env                  # build-time environment (per-host)
116|│   └── .dockerignore
117|├── firmware/                 # downloaded firmware files (not in git)
118|├── modules/                  # built .ko modules (not in git)
119|├── logs/                     # build logs (not in git)
120|└── README.md                 # this file
121|```
122|
123|## Making it work with Tvheadend / Docker
124|
125|To pass the DVB adapters into a Tvheadend container, add to the Tvheadend service in your `compose.yml`:
126|
127|```yaml
128|services:
129|  tvheadend:
130|    devices:
131|      - /dev/dvb:/dev/dvb
132|    privileged: true
133|    environment:
134|      - PUID=0
135|      - PGID=0
136|```
137|
138|Then recreate the container:
139|
140|```bash
141|docker compose up -d --force-recreate tvheadend
142|```
143|
144|Inside the container you should see `/dev/dvb/adapter0` and `/dev/dvb/adapter1`. Add DVB-T/T2 networks in the Tvheadend Web UI and run a channel scan.
145|
146|## Adding support for other tuners
147|
148|Edit `2_build_dvb.sh` and add the module paths to `MODULES_LIST`, then rebuild. You may also need to add the relevant `CONFIG_*` entries in `apply_patches.py` if they are not already enabled.
149|
150|## Persisting modules across reboots
151|
152|QNAP does **not** automatically reload custom kernel modules after a reboot. The fastest way to make the DVB setup survive reboots is to run a short shell script from QNAP's scheduled task / cron at startup.
153|
154|1. Create `/path/to/qnap-dvb/scripts/load-dvb.sh`:
155|
156|   ```bash
157|   #!/bin/sh
158|   # Load custom DVB modules on QNAP boot
159|   MODDIR="/lib/modules/$(uname -r)/extra"
160|   for mod in tveeprom tuner si2157 si2168 em28xx em28xx_dvb dvb_usb; do
161|       [ -f "$MODDIR/$mod.ko" ] && insmod "$MODDIR/$mod.ko" 2>/dev/null || true
162|   done
163|   ```
164|
165|2. Make it executable:
166|
167|   ```bash
168|   chmod +x /path/to/qnap-dvb/scripts/load-dvb.sh
169|   ```
170|
171|3. Add it to QNAP startup cron (`/etc/config/crontab`). In QTS Control Panel → System → Hardware → General, use **Schedule** → **Create** → **Trigger event** → **Startup**, or edit the crontab directly:
172|
173|   ```bash
174|   @reboot root /path/to/qnap-dvb/scripts/load-dvb.sh >> /path/to/qnap-dvb/logs/dvb-boot.log 2>&1
175|   ```
176|
177|   Then restart cron:
178|
179|   ```bash
180|   /etc/init.d/crond.sh restart
181|   ```
182|
183|4. Verify after next reboot:
184|
185|   ```bash
186|   lsmod | grep em28xx
187|   ls /dev/dvb
188|   dmesg | tail -20 | grep -E 'em28xx|si2168|si2157'
189|   ```
190|
191|## Persisting firmware across QTS / firmware updates
192|
193|QNAP firmware updates can overwrite `/lib/firmware/` and `/lib/modules/`. Keep a copy of your firmware files and rebuild modules after a major QTS update:
194|
195|```bash
196|# Keep firmware backup in the project directory
197|cp /lib/firmware/dvb-demod-si2168-*.fw /path/to/qnap-dvb/firmware/
198|
199|# After a QTS update, re-run the builder and reinstall modules
200|# (kernel version may have changed, so the old .ko files may not load)
201|cd /path/to/qnap-dvb/build
202|docker run --rm --user root \
203|  -v /path/to/qnap-dvb/build/src:/build/src \
204|  -v /path/to/qnap-dvb/modules:/modules-out:rw \
205|  -v /path/to/qnap-dvb/logs:/build/logs:rw \
206|  qnap-dvb-builder
207|
208|# Reinstall
209|cp /path/to/qnap-dvb/modules/*.ko /lib/modules/$(uname -r)/extra/
210|depmod -a $(uname -r)
211|cp /path/to/qnap-dvb/firmware/*.fw /lib/firmware/
212|```
213|
214|If the kernel version changes, the modules built for the old kernel will not load (`Invalid module format`). The builder fetches the GPL source matching `QNAP_VER` in `.env`, so update that value to your new QTS version before rebuilding.
215|
216|## Troubleshooting
217|
218|### `firmware file 'dvb-demod-si2168-02.fw' not found`
219|The Si2168 demodulator needs firmware. Copy the requested file to `/lib/firmware/` and reload the driver (or unplug/replug the USB tuner).
220|
221|### `scan no data, failed` in Tvheadend
222|- Verify the requested firmware loaded (`dmesg | grep si2168`).
223|- Check antenna/cable connection.
224|- Confirm the scan preset matches your region (DVB-T/T2 frequencies vary by transmitter).
225|- Try a manual mux frequency from your local broadcaster.
226|
227|### Build fails with `Module.symvers` errors
228|This happens when a module depends on symbols from another module that was not built first. Re-run the builder; the script now builds dependency subtrees (`drivers/media/common`, `drivers/media/tuners`, `drivers/media/dvb-frontends`) before the top-level em28xx modules and merges `Module.symvers` between stages.
229|
230|### Modules do not load after reboot
231|Check the boot log (`/path/to/qnap-dvb/logs/dvb-boot.log`) and confirm the startup cron entry is present. If QTS removed `/lib/modules/$(uname -r)/extra`, recreate it and reinstall the modules.
232|
233|## License
234|
235|The build scripts and Dockerfile are provided as-is for personal use. The QNAP GPL kernel source and Linux kernel modules are subject to their respective licenses (GPL v2).
236|
237|## Acknowledgements
238|
239|- [mammo0/qnap-qts-toolchain](https://github.com/mammo0/qnap-qts-toolchain) for the QNAP cross-toolchain Docker image.
240|- QNAP for publishing the GPL kernel source.
241|- LinuxTV / V4L-DVB project for the DVB drivers.
242|