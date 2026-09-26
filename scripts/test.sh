#!/usr/bin/env bash
# Runs the test suite headlessly. Integration tests run only when ULTRAVOX_API_KEY is set (it may
# be provided in a .env file at the repo root).
#
# Usage: scripts/test.sh [unit|integration] [extra GUT args...]
set -euo pipefail

cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

dir="res://test"
if [[ "${1:-}" == "unit" || "${1:-}" == "integration" ]]; then
  dir="res://test/$1"
  shift
fi

# Importing registers GDExtensions and global script classes, which a fresh checkout lacks.
"$GODOT" --headless --import >/dev/null 2>&1 || true
"$GODOT" --headless -s addons/gut/gut_cmdln.gd -gdir="$dir" -ginclude_subdirs -gexit "$@"
