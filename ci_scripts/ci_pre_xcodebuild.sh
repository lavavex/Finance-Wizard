#!/bin/sh
# Xcode Cloud: runs immediately before xcodebuild.
# 1) Lock project format for Cloud compatibility
# 2) Set CFBundleVersion / CURRENT_PROJECT_VERSION = CI_BUILD_NUMBER so
#    Cloud archives and local About match the same build counter.
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH" 2>/dev/null || cd "$(dirname "$0")/.."

chmod +x scripts/lock-xcode-project-format.sh
chmod +x scripts/set-build-number.sh
./scripts/lock-xcode-project-format.sh

if [ -n "${CI_BUILD_NUMBER:-}" ]; then
  echo "Xcode Cloud CI_BUILD_NUMBER=${CI_BUILD_NUMBER} → project CURRENT_PROJECT_VERSION"
  ./scripts/set-build-number.sh "$CI_BUILD_NUMBER"
else
  echo "warning: CI_BUILD_NUMBER unset; leaving CURRENT_PROJECT_VERSION unchanged"
fi
