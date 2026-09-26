#!/usr/bin/env bash
# Installs this project's development dependencies (godot-livekit and GUT) into addons/. Existing
# installs (including symlinks to local builds) are left alone.
set -euo pipefail

cd "$(dirname "$0")/.."
GODOT_LIVEKIT_VERSION="${GODOT_LIVEKIT_VERSION:-v0.3.3}"
GUT_VERSION="${GUT_VERSION:-9.5.0}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [[ ! -e addons/godot-livekit ]]; then
  echo "Installing godot-livekit $GODOT_LIVEKIT_VERSION"
  curl -fsSL -o "$tmp/godot-livekit.zip" \
    "https://github.com/NodotProject/godot-livekit/releases/download/$GODOT_LIVEKIT_VERSION/godot-livekit-release.zip"
  unzip -q "$tmp/godot-livekit.zip" -d "$tmp/godot-livekit"
  mv "$tmp/godot-livekit/addons/godot-livekit" addons/godot-livekit
fi

if [[ ! -e addons/gut ]]; then
  echo "Installing GUT $GUT_VERSION"
  curl -fsSL "https://github.com/bitwes/Gut/archive/refs/tags/v$GUT_VERSION.tar.gz" | tar -xz -C "$tmp"
  mv "$tmp/Gut-$GUT_VERSION/addons/gut" addons/gut
fi
