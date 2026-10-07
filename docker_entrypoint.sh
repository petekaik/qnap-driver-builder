#!/usr/bin/env bash
# Entrypoint for DVB module build container

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

# If a command is provided, run it; otherwise default to build
if [ "$1" = "build" ] || [ "$1" = "clean" ]; then
    exec "$@"
else
    exec ./2_build_dvb.sh
fi