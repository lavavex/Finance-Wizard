#!/bin/sh
# Xcode Cloud: runs immediately before xcodebuild.
# Keeps the project readable even if a local Xcode 26/27 bumped objectVersion to 110+.
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH" 2>/dev/null || cd "$(dirname "$0")/.."
chmod +x scripts/lock-xcode-project-format.sh
./scripts/lock-xcode-project-format.sh
