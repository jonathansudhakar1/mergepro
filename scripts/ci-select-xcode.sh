#!/bin/bash
# Selects the newest Xcode 27 (or later) installed on a CI runner and prints the toolchain in use.
set -euo pipefail
xcode=$(ls -d /Applications/Xcode_2[7-9]*.app /Applications/Xcode-2[7-9]*.app 2>/dev/null | sort -V | tail -n 1 || true)
if [[ -n "$xcode" ]]; then sudo xcode-select -s "$xcode/Contents/Developer"; fi
xcodebuild -version
xcrun --sdk macosx --show-sdk-version
