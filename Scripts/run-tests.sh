#!/usr/bin/env bash
# Scripts/run-tests.sh — runs Kytos-Tests and prints a clean summary.
set -euo pipefail
xcodebuild \
    -project Kytos.xcodeproj \
    -scheme Kytos-Tests \
    -destination 'platform=macOS' \
    test \
    -allowProvisioningUpdates \
    2>&1 \
  | grep -Ev 'pkg-config|jemalloc|packager'
