#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Archive Trillium for App Store Connect / TestFlight and optionally upload.
#
# Follows the same export path used by the AirLink archive scripts: the
# archive itself is unsigned, then `xcodebuild -exportArchive` with
# method `app-store-connect` and automatic signing produces the signed
# IPA (iOS) or pkg (macOS). Nothing is submitted for App Store review.
#
# Prerequisites (macOS with Xcode), unless DRY_RUN=1:
#   make apple-firmware apple-project
#   TEAM_ID set to the Apple Developer Team ID
#
# Signing needs ONE of:
#   - Xcode signed in to the team, so automatic signing can issue the
#     Apple Distribution certificate and App Store profile; or
#   - an App Store Connect API key:
#       ASC_KEY_PATH=/path/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=<uuid>
#
# Usage (from the repository root):
#   TEAM_ID=<team> apple/scripts/archive_testflight.sh ios
#   TEAM_ID=<team> UPLOAD=1 apple/scripts/archive_testflight.sh ios
#   TEAM_ID=<team> apple/scripts/archive_testflight.sh macos
#   TEAM_ID=<team> apple/scripts/archive_testflight.sh both
#   TEAM_ID=<team> DRY_RUN=1 apple/scripts/archive_testflight.sh ios
#
# Optional: TRILL_BUNDLE_ID overrides the placeholder in Base.xcconfig
# for this run by writing apple/Config/Local.xcconfig (git-ignored).
# DEVELOPMENT_TEAM is also written there when TEAM_ID is set.
# The script never commits that file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PLATFORM="${1:-ios}"
case "$PLATFORM" in
  ios|macos|both) ;;
  *)
    echo "usage: $0 [ios|macos|both]" >&2
    exit 2
    ;;
esac

DRY_RUN="${DRY_RUN:-0}"
UPLOAD="${UPLOAD:-0}"
DEST=export
if [ "$UPLOAD" = 1 ]; then
  DEST=upload
fi

if [ -z "${TEAM_ID:-}" ]; then
  echo "TEAM_ID is required (Apple Developer Team ID)." >&2
  exit 2
fi

AUTH=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
  if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ]; then
    echo "ASC_KEY_PATH is set; also set ASC_KEY_ID and ASC_ISSUER_ID." >&2
    exit 2
  fi
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

VERSION="$(sed -n 's/^MARKETING_VERSION = //p' apple/Config/Base.xcconfig | head -1)"
BUILD="$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' apple/Config/Base.xcconfig | head -1)"
OUT="${OUT_DIR:-$ROOT/dist/testflight}"
mkdir -p "$OUT"

write_export_options() {
  local dest="$1"
  local path="$2"
  cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>$dest</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
}

if [ -n "${TRILL_BUNDLE_ID:-}" ]; then
  printf 'DEVELOPMENT_TEAM = %s\nTRILL_BUNDLE_ID = %s\n' "$TEAM_ID" "$TRILL_BUNDLE_ID" > apple/Config/Local.xcconfig
else
  printf 'DEVELOPMENT_TEAM = %s\n' "$TEAM_ID" > apple/Config/Local.xcconfig
fi

IOS_OPTS="$OUT/ExportOptions-ios.plist"
MAC_OPTS="$OUT/ExportOptions-macos.plist"
write_export_options "$DEST" "$IOS_OPTS"
write_export_options "$DEST" "$MAC_OPTS"
echo "Wrote export options for $PLATFORM (version $VERSION build $BUILD, destination $DEST) in $OUT"

if [ "$DRY_RUN" = 1 ]; then
  # Local.xcconfig is git-ignored and may hold a team ID; drop the dry-run copy.
  rm -f apple/Config/Local.xcconfig
  exit 0
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "archive_testflight.sh needs macOS with Xcode (or DRY_RUN=1)." >&2
  exit 2
fi

PROJECT="$ROOT/apple/Trillium.xcodeproj"
if [ ! -d "$PROJECT" ]; then
  echo "missing $PROJECT; run make apple-project first." >&2
  exit 2
fi

archive_one() {
  local scheme="$1"
  local destination="$2"
  local archive="$3"
  local export_path="$4"
  local opts="$5"
  rm -rf "$archive" "$export_path"
  mkdir -p "$export_path"
  echo "Archiving $scheme ($destination) -> $archive"
  xcodebuild -project "$PROJECT" -scheme "$scheme" -configuration Release \
    -destination "$destination" -archivePath "$archive" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    archive
  echo "Exporting $scheme (destination $DEST)"
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_path" \
    -exportOptionsPlist "$opts" -allowProvisioningUpdates \
    ${AUTH[@]+"${AUTH[@]}"}
}

if [ "$PLATFORM" = "ios" ] || [ "$PLATFORM" = "both" ]; then
  archive_one TrilliumIOS "generic/platform=iOS" \
    "$OUT/Trillium-iOS-$VERSION-$BUILD.xcarchive" \
    "$OUT/export-ios" "$IOS_OPTS"
  ls "$OUT"/export-ios/*.ipa 2>/dev/null || true
fi
if [ "$PLATFORM" = "macos" ] || [ "$PLATFORM" = "both" ]; then
  archive_one TrilliumMac "generic/platform=macOS" \
    "$OUT/Trillium-macOS-$VERSION-$BUILD.xcarchive" \
    "$OUT/export-macos" "$MAC_OPTS"
  ls "$OUT"/export-macos/*.pkg "$OUT"/export-macos/*.ipa 2>/dev/null || true
fi

if [ "$UPLOAD" = 1 ]; then
  echo "Upload requested. The export step uploads to App Store Connect for TestFlight; it does not submit for App Store review."
else
  echo "Not uploaded. Re-run with UPLOAD=1 to upload for TestFlight, or use Xcode Organizer / Transporter."
fi
