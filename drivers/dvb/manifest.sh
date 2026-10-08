#!/bin/sh
# DVB family: Hauppauge WinTV-dualHD (USB 2040:8265) on a TS-X51.
# Values mirror the pre-plugin builder exactly. See docs/03 section 9.1.
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
# Dependency order, and load-bearing: the builder hands modpost each earlier
# directory's Module.symvers, so a directory listed before the one that needs
# its symbols is the difference between a module linking and a module silently
# not existing. em28xx needs tveeprom (drivers/media/common); si2168 and si2157
# need __regmap_init_i2c, so drivers/base/regmap is built even though it
# contributes nothing to DRIVER_MODULES — see docs/03 section 6.
DRIVER_DIRS="drivers/base/regmap drivers/media/dvb-core drivers/media/common \
drivers/media/v4l2-core drivers/media/dvb-frontends drivers/media/tuners \
drivers/media/i2c drivers/media/usb/dvb-usb drivers/media/usb/em28xx"
# dvb-core and v4l2-common are deliberately absent. Their configs below are =y,
# and a =y symbol is linked into the kernel image rather than emitted as a .ko:
# `obj-$(CONFIG_DVB_CORE) += dvb-core.o` in drivers/media/dvb-core/Makefile, and
# v4l2-common.o is one object inside the =y videodev.o composite in
# drivers/media/v4l2-core/Makefile. Both are built-in dependencies of the
# modules that matter. Any =y symbol listed here would print [MISS] at collect.
# `em28xx-v4l`, not `em28xx-v4l2`: the object is em28xx-v4l.o —
# `obj-$(CONFIG_VIDEO_EM28XX_V4L2) += em28xx-v4l.o` in
# drivers/media/usb/em28xx/Makefile. No kernel emits em28xx-v4l2.ko.
DRIVER_MODULES="em28xx em28xx-v4l em28xx-dvb em28xx-rc si2168 si2157 dvb-usb \
tveeprom tuner videobuf2-common videobuf2-memops videobuf2-v4l2 videobuf2-vmalloc"
DRIVER_LOAD_ORDER="videobuf2-common videobuf2-memops videobuf2-v4l2 \
videobuf2-vmalloc tuner tveeprom si2157 si2168 dvb-usb em28xx em28xx-rc em28xx-dvb"
DRIVER_SEARCH_ROOTS="drivers/media"
DRIVER_FIRMWARE="dvb-demod-si2168-b40-01.fw dvb-demod-si2168-d60-01.fw \
dvb-demod-si2168-02.fw"
DRIVER_REQUIRES=""
