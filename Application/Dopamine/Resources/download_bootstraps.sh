#!/bin/bash
set -e

echo "Using pre-patched /var/69 bootstrap files..."

# Verify bootstrap files exist (pre-copied, patched for /var/69)
if [ ! -f bootstrap_1800.tar.zst ]; then
    echo "ERROR: bootstrap_1800.tar.zst not found!"
    exit 1
fi
echo "✓ Found bootstrap_1800.tar.zst ($(du -h bootstrap_1800.tar.zst | cut -f1))"

if [ ! -f bootstrap_1900.tar.zst ]; then
    echo "ERROR: bootstrap_1900.tar.zst not found!"
    exit 1
fi
echo "✓ Found bootstrap_1900.tar.zst ($(du -h bootstrap_1900.tar.zst | cut -f1))"

# Verify pre-patched Sileo exists
if [ ! -f org.coolstar.sileo_2.5.1_iphoneos-arm64.deb ]; then
    echo "ERROR: org.coolstar.sileo_2.5.1_iphoneos-arm64.deb not found!"
    exit 1
fi
echo "✓ Found Sileo patched for /var/69 ($(du -h org.coolstar.sileo_2.5.1_iphoneos-arm64.deb | cut -f1))"

echo "All pre-patched files verified! Skipping Zebra (Sileo is sufficient)"

