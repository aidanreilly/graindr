#!/usr/bin/env bash
# Install the Sediment SuperCollider UGen plugin on norns (RPi 3B+).
#
# Run this on the norns device itself:
#   ssh we@norns.local
#   cd dust/code/graindr
#   ./install-sediment.sh
#
# Prerequisites (should already be present on stock norns):
#   supercollider-dev, cmake, g++

set -euo pipefail

SC_EXT_DIR="$HOME/.local/share/SuperCollider/Extensions"
WORK_DIR="/tmp/sediment-build"
SEDIMENT_REPO="https://github.com/bjarnig/Sediment.git"

cleanup() {
    echo "Cleaning up build directory..."
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "==> Checking build dependencies..."

missing=()
for pkg in cmake g++ supercollider-dev; do
    if [ "$pkg" = "supercollider-dev" ]; then
        if ! dpkg -s supercollider-dev >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    else
        if ! command -v "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    fi
done

if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing packages: ${missing[*]}"
    echo "Installing..."
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends "${missing[@]}"
fi

echo "==> Finding SuperCollider source headers..."

SC_PATH=""
SC_INCLUDE="/usr/include/SuperCollider"
if [ -f "$SC_INCLUDE/plugin_interface/SC_PlugIn.h" ]; then
    # Sediment's CMake expects SC_PATH/include/plugin_interface/SC_PlugIn.h,
    # i.e. SC_PATH pointing at the root of a full SC source checkout. Debian's
    # supercollider-dev package installs the same headers flat, one level up
    # from that (no extra "include" nesting), so shim it with a symlink
    # rather than cloning the whole SC source tree just for headers.
    SC_SHIM_DIR="$WORK_DIR/sc-include-shim"
    mkdir -p "$SC_SHIM_DIR"
    ln -sfn "$SC_INCLUDE" "$SC_SHIM_DIR/include"
    SC_PATH="$SC_SHIM_DIR"
fi

SC_SRC_DIR="$WORK_DIR/supercollider"
if [ -z "$SC_PATH" ]; then
    echo "    SC headers not found in system paths, fetching SC source..."
    mkdir -p "$WORK_DIR"

    sc_version=$(dpkg -s supercollider-server 2>/dev/null \
        | grep '^Version:' | awk '{print $2}' | sed 's/-.*//' || true)

    if [ -z "$sc_version" ]; then
        sc_version=$(scsynth -v 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1 || true)
    fi

    sc_tag="Version-3.14.1"
    if [ -n "$sc_version" ]; then
        sc_tag="Version-${sc_version}"
        echo "    Detected SC version: $sc_version"
    else
        echo "    Could not detect SC version, defaulting to 3.14.1"
    fi

    rm -rf "$SC_SRC_DIR"
    if ! git clone --depth 1 --branch "$sc_tag" \
        https://github.com/supercollider/supercollider.git "$SC_SRC_DIR" 2>/dev/null; then
        rm -rf "$SC_SRC_DIR"
        git clone --depth 1 \
            https://github.com/supercollider/supercollider.git "$SC_SRC_DIR"
    fi

    SC_PATH="$SC_SRC_DIR"
fi

echo "    SC source: $SC_PATH"

echo "==> Cloning Sediment..."
rm -rf "$WORK_DIR/Sediment"
git clone --depth 1 "$SEDIMENT_REPO" "$WORK_DIR/Sediment"

echo "==> Building for $(uname -m)..."
BUILD_DIR="$WORK_DIR/Sediment/build"

cmake -S "$WORK_DIR/Sediment" -B "$BUILD_DIR" \
    -DSC_PATH="$SC_PATH" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSUPERNOVA=OFF \
    -DBUILD_UNIVERSAL=OFF \
    -DNATIVE=ON \
    -DCMAKE_INSTALL_PREFIX="$SC_EXT_DIR"

nproc_count=$(nproc 2>/dev/null || echo 2)
cmake --build "$BUILD_DIR" --config Release -j"$nproc_count"

echo "==> Installing to $SC_EXT_DIR..."
mkdir -p "$SC_EXT_DIR"
cmake --install "$BUILD_DIR"

echo "==> Installed UGens:"
found_files=$(find "$SC_EXT_DIR" \( -name '*.so' -o -name '*.scx' \) 2>/dev/null || true)
if [ -n "$found_files" ]; then
    echo "$found_files"
else
    echo "    Warning: no .so/.scx files found under $SC_EXT_DIR — install may have failed or used an unexpected layout."
fi

echo
echo "Done. Restart SuperCollider to load the new UGens:"
echo "  norns.script.load('none')"
echo "  ;restart"
echo
echo "Then reload graindr/sediment."
