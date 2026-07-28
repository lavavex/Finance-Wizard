#!/bin/sh
# Xcode Cloud: after xcodebuild. Log the build number that was used so
# App Store Connect / TestFlight and About → Build stay aligned.
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH" 2>/dev/null || cd "$(dirname "$0")/.."

echo "---- Finance Wizard version stamp ----"
echo "CI_BUILD_NUMBER=${CI_BUILD_NUMBER:-unset}"
echo "CI_BUILD=${CI_BUILD:-unset}"
if [ -f ci_scripts/.last_build_number ]; then
  echo "project CURRENT_PROJECT_VERSION set to $(cat ci_scripts/.last_build_number)"
fi
if [ -f FinanceWizard.xcodeproj/project.pbxproj ]; then
  grep -m1 "CURRENT_PROJECT_VERSION" FinanceWizard.xcodeproj/project.pbxproj || true
  grep -m1 "MARKETING_VERSION" FinanceWizard.xcodeproj/project.pbxproj || true
fi
echo "--------------------------------------"
