#!/usr/bin/env bash
set -e

cd "$(dirname "$0")/BaseBin"

echo "Building all BaseBin components locally..."

# Build individual components
echo "Building ChOma..."
make ChOma

echo "Building XPF..."
make XPF  

echo "Building MachOMerger..."
make MachOMerger

echo "Using pre-built opainject..."
mkdir -p .build
cp prebuilt/opainject .build/opainject

echo "Building libjailbreak..."
make libjailbreak

echo "Building systemhook..."
make systemhook

echo "Building forkfix..."
make forkfix

echo "Building launchdhook..."
make launchdhook

echo "Building hookd..."
make hookd

echo "Building boomerang..."
make boomerang

echo "Building jbctl..."
make jbctl

echo "Building idownloadd..."
make idownloadd

echo "Building watchdoghook..."
make watchdoghook

echo "Building rootlesshooks..."
make rootlesshooks

echo "Building dopamine..."
make dopamine

echo "Building dyldhook..."
make dyldhook

echo "All components built successfully!"
echo "Now copying binaries to prebuilt directory..."

mkdir -p prebuilt

# Copy all built binaries
cp .build/libchoma.dylib prebuilt/ 2>/dev/null || true
cp .build/libxpf.dylib prebuilt/ 2>/dev/null || true
cp .build/MachOMerger prebuilt/ 2>/dev/null || true
cp .build/libjailbreak.dylib prebuilt/ 2>/dev/null || true
cp .build/systemhook.dylib prebuilt/ 2>/dev/null || true
cp .build/forkfix.dylib prebuilt/ 2>/dev/null || true
cp .build/launchdhook.dylib prebuilt/ 2>/dev/null || true
cp .build/hookd prebuilt/ 2>/dev/null || true
cp .build/boomerang prebuilt/ 2>/dev/null || true
cp .build/jbctl prebuilt/ 2>/dev/null || true
cp .build/idownloadd prebuilt/ 2>/dev/null || true
cp .build/watchdoghook.dylib prebuilt/ 2>/dev/null || true
cp .build/rootlesshooks.dylib prebuilt/ 2>/dev/null || true
cp .build/dopamine prebuilt/ 2>/dev/null || true
cp .build/*.dylib prebuilt/ 2>/dev/null || true

echo "Done! Check prebuilt directory for all binaries."
ls -lh prebuilt/
