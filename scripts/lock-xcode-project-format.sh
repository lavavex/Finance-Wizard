#!/usr/bin/env bash
# Force FinanceWizard.xcodeproj to a format Xcode Cloud can open.
#
# Local Xcode 26/27 may rewrite objectVersion to 110 (or higher). Older
# Xcode Cloud images cannot open that. Run this before commit, or let
# ci_scripts/ci_pre_xcodebuild.sh run it automatically on Cloud.
#
# Compatible floor: objectVersion 77 (Xcode 16 folder-sync projects).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBX="$ROOT/FinanceWizard.xcodeproj/project.pbxproj"

if [[ ! -f "$PBX" ]]; then
  echo "error: missing $PBX" >&2
  # Older workflows may still look for FinanceWidget — fail with a clear hint.
  if [[ -f "$ROOT/FinanceWidget.xcodeproj/project.pbxproj" ]]; then
    echo "error: found FinanceWidget.xcodeproj; rename/update the Xcode Cloud workflow to FinanceWizard.xcodeproj" >&2
  fi
  exit 1
fi

# Snapshot before
BEFORE="$(grep -E 'objectVersion|preferredProjectObjectVersion|validationLevel' "$PBX" || true)"

# Pin format
# shellcheck disable=SC2016
perl -i -pe 's/^(\tobjectVersion = )\d+;/${1}77;/' "$PBX"
perl -i -pe 's/^(\t\t\tpreferredProjectObjectVersion = )\d+;/${1}77;/' "$PBX"

# Xcode 26+ sometimes adds validationLevel = 1; strip it for older tools
perl -i -ne 'print unless /^\tvalidationLevel = \d+;/' "$PBX"

# Keep CreatedOnToolsVersion from looking like a future Xcode when possible
perl -i -pe 's/CreatedOnToolsVersion = 2[6-9]\.\d+/CreatedOnToolsVersion = 16.0/g' "$PBX"
perl -i -pe 's/CreatedOnToolsVersion = 3\d\.\d+/CreatedOnToolsVersion = 16.0/g' "$PBX"

AFTER="$(grep -E 'objectVersion|preferredProjectObjectVersion|validationLevel|CreatedOnToolsVersion' "$PBX" | head -20 || true)"

echo "Locked Xcode project format:"
echo "$AFTER"

if echo "$AFTER" | grep -q 'objectVersion = 77'; then
  echo "OK: objectVersion = 77"
else
  echo "error: failed to set objectVersion = 77" >&2
  exit 1
fi
