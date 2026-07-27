#!/bin/sh
# Xcode Cloud: runs after clone. Make lock script executable early.
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH" 2>/dev/null || cd "$(dirname "$0")/.."
chmod +x scripts/lock-xcode-project-format.sh
chmod +x ci_scripts/ci_pre_xcodebuild.sh
# Also lock immediately after clone so any inspection tooling sees a good project.
./scripts/lock-xcode-project-format.sh
