#!/bin/bash
# Verification for local use and CI: package tests, unsigned Debug builds of both apps (with test targets), the
# app unit tests (MergeProAppTests), an unsigned Release build of the shipped app, and a report-only swift-format lint.
# Runs every step and fails at the end if any test or build step failed. UI tests are not run here.
#   scripts/verify.sh
# MERGEPRO_DERIVED_DATA overrides the app build's derived data folder (default .build/verify).
set -uo pipefail
cd "$(dirname "$0")/.."
readonly derived="${MERGEPRO_DERIVED_DATA:-.build/verify}"
failed=()

step() {
    local name="$1"; shift
    printf '\n== %s\n' "$name"
    if "$@"; then printf '== %s: passed\n' "$name"; else printf '== %s: FAILED\n' "$name"; failed+=("$name"); fi
}

# The lock files serialize runs that share a package's .build folder (parallel agents, editors, CI steps).
step 'MergeProCore tests' bash -c 'cd Packages/MergeProCore && lockf -k /tmp/mergepro-core-test.lock swift test'
step 'MergeProRendering tests' bash -c 'cd Packages/MergeProRendering && lockf -k /tmp/mergepro-rendering-test.lock swift test'
step 'App build (unsigned)' lockf -k /tmp/mergepro-xcodebuild.lock xcodebuild -project MergePro.xcodeproj -scheme MergePro \
    -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build-for-testing
# Hosted by the app built above, which detects XCTest and never opens the real store, Keychain or network.
rm -rf "$derived/MergeProAppTests.xcresult"
step 'App unit tests' lockf -k /tmp/mergepro-xcodebuild.lock xcodebuild -project MergePro.xcodeproj -scheme MergePro \
    -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
    -resultBundlePath "$derived/MergeProAppTests.xcresult" test-without-building -only-testing:MergeProAppTests
# The configuration scripts/build-local.sh signs by default; no other step compiles Release.
step 'App Release build (unsigned)' lockf -k /tmp/mergepro-xcodebuild.lock xcodebuild -project MergePro.xcodeproj -scheme MergePro \
    -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build
# App/Fixtures compiles only into the separate fixture app, so the shipped app's build cannot catch its breakage.
step 'Fixture app build (unsigned)' lockf -k /tmp/mergepro-xcodebuild.lock xcodebuild -project MergePro.xcodeproj -scheme MergeProFixtures \
    -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build-for-testing

if [[ -f .swift-format ]]; then
    printf '\n== swift-format lint (report only)\n'
    if swift format --version > /dev/null 2>&1; then
        mkdir -p .build
        swift format lint --configuration .swift-format --recursive App Packages/MergeProCore/Sources Packages/MergeProCore/Tests \
            Packages/MergeProRendering/Sources Packages/MergeProRendering/Tests Tests > .build/swift-format-lint.txt 2>&1 || true
        head -n 50 .build/swift-format-lint.txt
        printf '== swift-format lint: %s findings, full list in .build/swift-format-lint.txt (not enforced yet)\n' \
            "$(grep -c 'warning:\|error:' .build/swift-format-lint.txt || true)"
    else
        echo '== swift-format unavailable; lint skipped'
    fi
fi

if (( ${#failed[@]} )); then
    printf '\nFailed: %s\n' "${failed[*]}"
    exit 1
fi
printf '\nAll verification steps passed.\n'
