#!/usr/bin/env bash
set -e
cd /build

if [ -f .env ]; then
    . .env
fi

chmod +x *.sh 2>/dev/null || true
ls -la *.sh

echo "=== Build Environment ==="
gcc --version 2>/dev/null | head -1
ld --version 2>/dev/null | head -1
echo "Kernel: $(uname -r)"
echo "Arch: $(uname -m)"
echo "========================"

# Run build as user 1000 (builder)
./2_build_dvb.sh build
