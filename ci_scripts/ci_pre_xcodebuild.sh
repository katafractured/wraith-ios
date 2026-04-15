#!/bin/bash
# Runs before xcodebuild archive.
# Sets CURRENT_PROJECT_VERSION to CI_BUILD_NUMBER so every Xcode Cloud run
# gets a unique, auto-incrementing build number without touching the project file.
# MARKETING_VERSION is left as-is from the project file.

set -euo pipefail

if [[ -z "${CI_BUILD_NUMBER:-}" ]]; then
  echo "ci_pre_xcodebuild: CI_BUILD_NUMBER not set — running outside Xcode Cloud, skipping."
  exit 0
fi

echo "ci_pre_xcodebuild: setting build number to $CI_BUILD_NUMBER"
PBXPROJ="$(dirname "$0")/../WraithVPN.xcodeproj/project.pbxproj"
sed -i "" "s/CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = ${CI_BUILD_NUMBER}/g" "$PBXPROJ"
echo "ci_pre_xcodebuild: done"
