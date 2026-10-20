#!/bin/bash
# Archives MergePro once and exports it twice: a Mac App Store package (uploaded to App Store Connect) and a Developer ID
# build that is notarized, stapled and zipped for GitHub Releases. Used by .github/workflows/release.yml; it can also run
# locally with the same environment.
#
# Required environment:
#   VERSION                       marketing version, for example 1.2.0
#   BUILD_NUMBER                  monotonically increasing build number (App Store Connect rejects reused numbers)
#   APPLE_TEAM_ID                 Apple Developer team ID
#   ASC_KEY_ID, ASC_ISSUER_ID     App Store Connect API key (Admin or App Manager role)
#   ASC_KEY_PATH                  path to that key's AuthKey_<id>.p8 file
#   MERGEPRO_GITHUB_CLIENT_ID     public client ID of the GitHub OAuth App the shipped app signs in with
# Optional:
#   UPLOAD_TO_APP_STORE=false     skip the App Store Connect upload
#   OUTPUT_DIR                    where artifacts go (default .build/release)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?}" "${BUILD_NUMBER:?}" "${APPLE_TEAM_ID:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_PATH:?}" "${MERGEPRO_GITHUB_CLIENT_ID:?}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must look like 1.2.3, got '$VERSION'" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "BUILD_NUMBER must be a positive integer" >&2; exit 1; }
readonly output="${OUTPUT_DIR:-.build/release}"
readonly archive="$output/MergePro.xcarchive"
readonly auth=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
mkdir -p "$output"
rm -rf "$archive" "$output/app-store" "$output/developer-id"

# The shipped app's default OAuth client ID; users can still override it in Settings.
printf 'MERGEPRO_GITHUB_CLIENT_ID = %s\n' "$MERGEPRO_GITHUB_CLIENT_ID" > Config/GitHub.xcconfig.local

xcodebuild archive -project MergePro.xcodeproj -scheme MergePro -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" "${auth[@]}" \
    ARCHS=arm64 CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY='Apple Development' DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

export_options() { # method destination
    cat > "$output/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>method</key><string>$1</string>
    <key>destination</key><string>$2</string>
    <key>teamID</key><string>$APPLE_TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
    echo "$output/$1.plist"
}

# Mac App Store: a signed installer package, uploaded straight to App Store Connect (then submit it for review there).
if [[ "${UPLOAD_TO_APP_STORE:-true}" == true ]]; then
    xcodebuild -exportArchive -archivePath "$archive" -exportPath "$output/app-store" \
        -exportOptionsPlist "$(export_options app-store-connect upload)" "${auth[@]}"
else
    xcodebuild -exportArchive -archivePath "$archive" -exportPath "$output/app-store" \
        -exportOptionsPlist "$(export_options app-store-connect export)" "${auth[@]}"
fi

# Developer ID: notarized for download from GitHub Releases.
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$output/developer-id" \
    -exportOptionsPlist "$(export_options developer-id export)" "${auth[@]}"
readonly app="$output/developer-id/MergePro.app"
codesign --verify --deep --strict --verbose=2 "$app"
readonly zip="$output/MergePro-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait --timeout 30m
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
rm "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
(cd "$output" && shasum -a 256 "MergePro-$VERSION.zip" | tee "MergePro-$VERSION.zip.sha256")
echo "Release artifacts in $output"
