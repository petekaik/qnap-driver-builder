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
