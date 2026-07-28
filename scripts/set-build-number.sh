#!/bin/sh
# Set CURRENT_PROJECT_VERSION for all targets in FinanceWizard.xcodeproj.
# Usage:
#   ./scripts/set-build-number.sh 42
#   CI_BUILD_NUMBER=42 ./scripts/set-build-number.sh
set -e

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
PBX="$ROOT/FinanceWizard.xcodeproj/project.pbxproj"

BUILD="${1:-${CI_BUILD_NUMBER:-}}"
if [ -z "$BUILD" ]; then
  echo "usage: $0 <build-number>" >&2
  echo "   or: CI_BUILD_NUMBER=<n> $0" >&2
  exit 1
fi

# Integer only (Xcode Cloud CI_BUILD_NUMBER is an integer)
case "$BUILD" in
  ''|*[!0-9]*)
    echo "error: build number must be a positive integer (got: $BUILD)" >&2
    exit 1
    ;;
esac

if [ ! -f "$PBX" ]; then
  echo "error: missing $PBX" >&2
  exit 1
fi

# Portable in-place replace for CURRENT_PROJECT_VERSION = N;
# (matches app + widget Debug/Release)
if sed --version >/dev/null 2>&1; then
  # GNU sed
  sed -i -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${BUILD};/g" "$PBX"
else
  # BSD sed (macOS)
  sed -i '' -E "s/CURRENT_PROJECT_VERSION = [0-9]+;/CURRENT_PROJECT_VERSION = ${BUILD};/g" "$PBX"
fi

# Record last applied number for local reference / tooling
mkdir -p "$ROOT/ci_scripts"
echo "$BUILD" > "$ROOT/ci_scripts/.last_build_number"

COUNT="$(grep -c "CURRENT_PROJECT_VERSION = ${BUILD};" "$PBX" || true)"
echo "CURRENT_PROJECT_VERSION → ${BUILD} (${COUNT} entries in project.pbxproj)"
