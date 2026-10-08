#!/usr/bin/env python3
"""Write KEY=VALUE tokens into a kernel .config.

Driver-neutral on purpose: every value this writes comes from a driver
manifest (drivers/<name>/manifest.sh), so this script knows nothing about any
particular driver. The =y/=m split it writes is load-bearing — see
docs/03-modular-driver-builder-design.md invariant 4.

    apply_configs.py <config-file> KEY=VALUE [KEY=VALUE ...]
"""
import sys


def parse_tokens(tokens):
    wanted = {}
    for token in tokens:
        key, sep, value = token.partition("=")
        if not sep or not key:
            sys.stderr.write("apply_configs.py: not a KEY=VALUE token: %s\n" % token)
            return None
        wanted[key] = value
    return wanted


def apply(cfg_path, wanted):
    with open(cfg_path) as handle:
        lines = handle.read().split("\n")

    replaced = set()
    for index, line in enumerate(lines):
        for key, value in wanted.items():
            # The "=" guards against CONFIG_USB matching CONFIG_USB_SERIAL.
            if line.startswith(key + "="):
                replaced.add(key)
                lines[index] = key + "=" + value

    for key, value in wanted.items():
        if key not in replaced:
            lines.append(key + "=" + value)

    with open(cfg_path, "w") as handle:
        handle.write("\n".join(lines))

    return len(wanted)


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    wanted = parse_tokens(argv[2:])
    if wanted is None:
        return 2
    apply(argv[1], wanted)
    print("Applied %d config entries to %s" % (len(wanted), argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
