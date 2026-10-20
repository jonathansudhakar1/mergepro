#!/bin/bash
# Signed local builds with an identity already in your keychain; never asks Xcode to manage provisioning.
# Config/Signing.xcconfig.local (git-ignored) names the identity (certificate SHA-1) and team; MERGEPRO_SIGNING_IDENTITY
# and MERGEPRO_TEAM_ID override them.
#   scripts/build-local.sh             signed Release app: no get-task-allow, hardened runtime
#   scripts/build-local.sh --debug     signed Debug app (debuggable)
#   scripts/build-local.sh --fixtures  signed Debug fixtures app (fixtures require DEBUG)
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -eq 0 ]]; then
    readonly scheme='MergePro' configuration='Release' derived='.build/xcode'
elif [[ "${1:-}" == "--debug" && $# -eq 1 ]]; then
    readonly scheme='MergePro' configuration='Debug' derived='.build/xcode'
elif [[ "${1:-}" == "--fixtures" && $# -eq 1 ]]; then
    readonly scheme='MergeProFixtures' configuration='Debug' derived='.build/xcode-fixtures'
else
    echo 'Usage: scripts/build-local.sh [--debug | --fixtures]' >&2
    exit 2
fi
readonly app="$derived/Build/Products/$configuration/$scheme.app"

if [[ ! -f Config/Signing.xcconfig.local ]]; then
    echo 'Missing Config/Signing.xcconfig.local. Set CODE_SIGN_IDENTITY (certificate SHA-1) and DEVELOPMENT_TEAM there.' >&2
    exit 1
fi
setting() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" Config/Signing.xcconfig.local | tail -n 1; }
readonly identity="${MERGEPRO_SIGNING_IDENTITY:-$(setting CODE_SIGN_IDENTITY)}"
readonly team="${MERGEPRO_TEAM_ID:-$(setting DEVELOPMENT_TEAM)}"
if [[ ! "$identity" =~ ^[0-9A-F]{40}$ || -z "$team" ]]; then
    echo 'Config/Signing.xcconfig.local needs CODE_SIGN_IDENTITY as a 40-character certificate SHA-1 and DEVELOPMENT_TEAM.' >&2
    exit 1
fi
mkdir -p .build/evidence
run_dir=$(mktemp -d "$PWD/.build/evidence/signing-XXXXXXXX")
printf '%s %s\n' "$scheme" "$configuration" > "$run_dir/build-target.txt"
security find-identity -v -p codesigning > "$run_dir/identities-before.txt"
if ! awk -v expected="$identity" '$2 == expected { found=1 } END { exit !found }' "$run_dir/identities-before.txt"; then
    echo "Existing signing identity $identity is unavailable, expired, or missing its private key. Build stopped." >&2
    exit 1
fi
# Signing a temporary local executable proves private-key access, beyond certificate presence.
cp /usr/bin/true "$run_dir/private-key-probe"
if ! codesign --force --sign "$identity" "$run_dir/private-key-probe" > "$run_dir/preflight.txt" 2>&1; then
    cat "$run_dir/preflight.txt" >&2
    echo "Private key for $identity could not sign. Build stopped without changing keychains or identities." >&2
    exit 1
fi
rm "$run_dir/private-key-probe"
xcodebuild -project MergePro.xcodeproj -scheme "$scheme" \
    -configuration "$configuration" -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived" CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" build \
    2>&1 | tee "$run_dir/build.log"
security find-identity -v -p codesigning > "$run_dir/identities-after.txt"
if ! cmp "$run_dir/identities-before.txt" "$run_dir/identities-after.txt"; then
    echo 'Signing identity inventory changed during build. Verification failed.' >&2
    exit 1
fi
cert_dir=$(mktemp -d)
trap 'rm -rf "$cert_dir"' EXIT
codesign -d --extract-certificates="$cert_dir/cert" "$app" 2> "$run_dir/certificate-extraction.txt"
fingerprint=$(shasum -a 1 "$cert_dir/cert0" | awk '{ print toupper($1) }')
printf '%s\n' "$fingerprint" > "$run_dir/certificate-sha1.txt"
if [[ "$fingerprint" != "$identity" ]]; then
    echo "App certificate fingerprint mismatch: expected $identity, got $fingerprint" >&2
    exit 1
fi
codesign --verify --strict --verbose=2 "$app" 2>&1 | tee "$run_dir/signature-verification.txt"
codesign -d --verbose=4 "$app" 2> "$run_dir/signature-details.txt"
codesign -d --entitlements - --xml "$app" > "$run_dir/entitlements.plist" 2> "$run_dir/entitlements-stderr.txt"
if ! grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' "$run_dir/signature-details.txt"; then
    echo "$app is not signed with the hardened runtime." >&2
    exit 1
fi
if grep -q 'com.apple.security.get-task-allow' "$run_dir/entitlements.plist"; then
    if [[ "$configuration" == 'Release' ]]; then
        echo "$app carries com.apple.security.get-task-allow; a Release build must not be debuggable." >&2
        exit 1
    fi
    echo 'get-task-allow: present (Debug build)' > "$run_dir/debuggable.txt"
else
    echo 'get-task-allow: absent' > "$run_dir/debuggable.txt"
fi
printf 'Verified %s %s %s with unchanged identity inventory, hardened runtime, %s. Evidence: %s\n' \
    "$scheme" "$configuration" "$fingerprint" "$(cat "$run_dir/debuggable.txt")" "$run_dir"
