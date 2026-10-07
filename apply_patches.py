import sys

cfg_path = sys.argv[1]

modules = {
    'CONFIG_MEDIA_SUPPORT': 'y',
    'CONFIG_MEDIA_CAMERA_SUPPORT': 'y',
    'CONFIG_VIDEO_DEV': 'y',
    'CONFIG_VIDEO_V4L2': 'y',
    'CONFIG_VIDEO_V4L2_SUBDEV_API': 'y',
    'CONFIG_DVB_CORE': 'y',
    'CONFIG_DVB_NET': 'm',
    'CONFIG_DVB_DEMUX': 'm',
    'CONFIG_USB': 'y',
    'CONFIG_USB_SUPPORT': 'y',
    'CONFIG_USB_COMMON': 'm',
    'CONFIG_USB_CORE': 'm',
    'CONFIG_VIDEOBUF2_CORE': 'y',
    'CONFIG_VIDEOBUF2_MEMOPS': 'm',
    'CONFIG_VIDEOBUF2_VMALLOC': 'm',
    'CONFIG_VIDEOBUF2_DMA_CONTIG': 'm',
    'CONFIG_VIDEOBUF2_DMA_SG': 'm',
    'CONFIG_V4L2_MEM2MEM_DEV': 'y',
    'CONFIG_RC_CORE': 'm',
    'CONFIG_RC_DEVICES': 'y',
    'CONFIG_VIDEO_EM28XX': 'm',
    'CONFIG_VIDEO_EM28XX_V4L2': 'm',
    'CONFIG_VIDEO_EM28XX_DVB': 'm',
    'CONFIG_VIDEO_EM28XX_RC': 'm',
    'CONFIG_DVB_SI2165': 'm',
    'CONFIG_DVB_SI2168': 'm',
    'CONFIG_MEDIA_TUNER_SI2157': 'm',
    'CONFIG_DVB_USB': 'm',
    'CONFIG_DVB_USB_V2': 'm',
    'CONFIG_DVB_TUNER_XC5000': 'm',
    'CONFIG_DVB_TUNER_DIB0070': 'm',
}

with open(cfg_path, 'r') as f:
    content = f.read()

lines = content.split('\n')
existing = set()
for i, line in enumerate(lines):
    for cfg_name in modules:
        if line.startswith(cfg_name + '='):
            existing.add(cfg_name)
            lines[i] = cfg_name + '=' + modules[cfg_name]

for cfg_name, value in modules.items():
    if cfg_name not in existing:
        lines.append(cfg_name + '=' + value)

with open(cfg_path, 'w') as f:
    f.write('\n'.join(lines))

print('Patched ' + str(len(modules)) + ' configs in ' + cfg_path)
