#!/usr/bin/env bash
# Entrypoint for the kernel-module build container

# Source env if .env exists (in case container is run with persistent volume)
if [ -f ".env" ]; then
    . .env
fi

# Create dirs if missing
mkdir -p /modules-out /build

# Make scripts executable
chmod +x *.sh 2>/dev/null || true

# Show toolchain info
echo "=== Build Environment ==="
gcc --version 2>/dev/null | head -1
ld --version 2>/dev/null | head -1
echo "Kernel: $(uname -r)"
echo "Arch: $(uname -m)"
echo "========================"

# `build` and `clean` are subcommands of 2_build_modules.sh, not programs: pass
# them through rather than exec'ing them. Anything else (or nothing) builds.
exec ./2_build_modules.sh "$@"