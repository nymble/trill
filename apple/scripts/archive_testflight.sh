#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Archive Trillium for App Store Connect / TestFlight and optionally upload.
#
# Cloud-managed signing: `xcodebuild` archive and `-exportArchive` use
# automatic signing, `-allowProvisioningUpdates`, and (when present) an
# App Store Connect API key (`-authenticationKeyPath`,
# `-authenticationKeyID`, `-authenticationKeyIssuerID`). The export is
# always written locally (method `app-store-connect`, destination
# `export`). For macOS the export must be a pkg signed with Mac
# Installer Distribution (the app itself with Apple Distribution).
# Upload, if requested, is a separate
# `xcrun altool --upload-app --apiKey --apiIssuer` step. Nothing is
# submitted for App Store review.
#
# App Store Connect requires the iOS 26 SDK (Xcode 26 or later). The
# GitHub workflow selects that toolchain and fails if it is older.
#
# Prerequisites (macOS with Xcode 26+), unless DRY_RUN=1:
#   make apple-firmware apple-project
#   TEAM_ID set to the Apple Developer Team ID
#
# Signing needs ONE of:
#   - Xcode signed in to the team, so automatic signing can issue the
#     Apple Distribution certificate and App Store profile; or
#   - an App Store Connect API key, as either:
#       ASC_KEY_PATH=/path/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=<uuid>
#     or ASC_KEY_P8 set to the raw PEM or its base64, plus ASC_KEY_ID and
#     ASC_ISSUER_ID. The .p8 is never committed.
#
# Usage (from the repository root):
#   TEAM_ID=<team> apple/scripts/archive_testflight.sh ios
#   TEAM_ID=<team> UPLOAD=1 apple/scripts/archive_testflight.sh ios
#   TEAM_ID=<team> apple/scripts/archive_testflight.sh macos
#   TEAM_ID=<team> apple/scripts/archive_testflight.sh both
#   TEAM_ID=<team> DRY_RUN=1 apple/scripts/archive_testflight.sh ios
#
# Optional: TRILL_BUNDLE_ID overrides the committed ID (net.nymbus.trillium)
# for this run by writing apple/Config/Local.xcconfig (git-ignored).
# DEVELOPMENT_TEAM is also written there when TEAM_ID is set.
# CURRENT_PROJECT_VERSION, if set in the environment, overrides the
# committed build number (the workflow passes github.run_number).
# The script never commits that file. It also clears the committed
# ad-hoc Mac identity (CODE_SIGN_IDENTITY[sdk=macosx*] = -) so archive
# and export can use cloud-managed Apple Distribution signing.
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

if [ -z "${TEAM_ID:-}" ]; then
  echo "TEAM_ID is required (Apple Developer Team ID)." >&2
  exit 2
fi

VERSION="$(sed -n 's/^MARKETING_VERSION = //p' apple/Config/Base.xcconfig | head -1)"
BUILD="$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' apple/Config/Base.xcconfig | head -1)"
if [ -n "${CURRENT_PROJECT_VERSION:-}" ]; then
  BUILD="$CURRENT_PROJECT_VERSION"
fi
OUT="${OUT_DIR:-$ROOT/dist/testflight}"
mkdir -p "$OUT"

# Write ASC_KEY_P8 (raw PEM or base64) to $1. Never prints the material.
write_key_file() {
  local dest="$1"
  local src="${ASC_KEY_P8:-}"
  if [ -z "$src" ]; then
    echo "ASC_KEY_P8 is empty." >&2
    return 1
  fi
  mkdir -p "$(dirname "$dest")"
  if printf '%s' "$src" | grep -q "BEGIN PRIVATE KEY"; then
    printf '%s\n' "$src" > "$dest"
  else
    if ! printf '%s' "$src" | python3 -c 'import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' > "$dest"; then
      echo "ASC_KEY_P8 is neither a PEM nor valid base64." >&2
      rm -f "$dest"
      return 1
    fi
    if ! grep -q "BEGIN" "$dest"; then
      echo "ASC_KEY_P8 decoded but is not a PEM key." >&2
      rm -f "$dest"
      return 1
    fi
  fi
  chmod 600 "$dest"
}

CREATED_KEY=""
ALTOOL_KEY_COPY=""
if [ -z "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_P8:-}" ]; then
  ASC_KEY_PATH="$OUT/AuthKey_${ASC_KEY_ID:-key}.p8"
  write_key_file "$ASC_KEY_PATH"
  CREATED_KEY="$ASC_KEY_PATH"
fi

AUTH=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
  if [ -z "${ASC_KEY_ID:-}" ] || [ -z "${ASC_ISSUER_ID:-}" ]; then
    echo "An API key is set; also set ASC_KEY_ID and ASC_ISSUER_ID." >&2
    exit 2
  fi
  if [ ! -f "$ASC_KEY_PATH" ]; then
    echo "ASC_KEY_PATH is not a file: $ASC_KEY_PATH" >&2
    exit 2
  fi
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

if [ "$UPLOAD" = 1 ] && [ "$DRY_RUN" != 1 ] && [ "${#AUTH[@]}" -eq 0 ]; then
  echo "UPLOAD=1 needs an App Store Connect API key (ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH or ASC_KEY_P8)." >&2
  exit 2
fi

write_export_options() {
  local path="$1"
  cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST
}

# Override Base.xcconfig for this run only (git-ignored). Clear the
# committed ad-hoc Mac identity so cloud-managed Apple Distribution
# (and, at export, Mac Installer Distribution) can be used.
{
  printf 'DEVELOPMENT_TEAM = %s\n' "$TEAM_ID"
  printf 'CODE_SIGN_STYLE = Automatic\n'
  printf 'CODE_SIGN_IDENTITY[sdk=macosx*] =\n'
  if [ -n "${CURRENT_PROJECT_VERSION:-}" ]; then
    printf 'CURRENT_PROJECT_VERSION = %s\n' "$CURRENT_PROJECT_VERSION"
  fi
  if [ -n "${TRILL_BUNDLE_ID:-}" ]; then
    printf 'TRILL_BUNDLE_ID = %s\n' "$TRILL_BUNDLE_ID"
  fi
} > apple/Config/Local.xcconfig

IOS_OPTS="$OUT/ExportOptions-ios.plist"
MAC_OPTS="$OUT/ExportOptions-macos.plist"
write_export_options "$IOS_OPTS"
write_export_options "$MAC_OPTS"
echo "Wrote export options for $PLATFORM (version $VERSION build $BUILD, destination export) in $OUT"
if [ "$UPLOAD" = 1 ]; then
  echo "UPLOAD=1: after export, would upload with xcrun altool --upload-app --apiKey --apiIssuer (iOS IPA and/or macOS pkg). Not a review submission."
fi

if [ "$DRY_RUN" = 1 ]; then
  rm -f apple/Config/Local.xcconfig
  if [ "${KEEP_ASC_KEY:-0}" != 1 ]; then
    [ -n "$CREATED_KEY" ] && rm -f "$CREATED_KEY"
  fi
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

# altool looks for AuthKey_<id>.p8 in these directories.
install_altool_key() {
  if [ "${#AUTH[@]}" -eq 0 ]; then
    return 0
  fi
  local dir="$HOME/.appstoreconnect/private_keys"
  mkdir -p "$dir"
  local dest="$dir/AuthKey_${ASC_KEY_ID}.p8"
  if [ ! -f "$dest" ]; then
    cp "$ASC_KEY_PATH" "$dest"
    chmod 600 "$dest"
    ALTOOL_KEY_COPY="$dest"
  fi
}

cleanup() {
  rm -f apple/Config/Local.xcconfig
  [ -n "$CREATED_KEY" ] && rm -f "$CREATED_KEY"
  [ -n "$ALTOOL_KEY_COPY" ] && rm -f "$ALTOOL_KEY_COPY"
}
trap cleanup EXIT

archive_one() {
  local scheme="$1"
  local destination="$2"
  local archive="$3"
  local export_path="$4"
  local opts="$5"
  rm -rf "$archive" "$export_path"
  mkdir -p "$export_path"
  echo "Archiving $scheme ($destination) with automatic, cloud-managed signing -> $archive"
  xcodebuild -project "$PROJECT" -scheme "$scheme" -configuration Release \
    -destination "$destination" -archivePath "$archive" \
    CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    -allowProvisioningUpdates \
    ${AUTH[@]+"${AUTH[@]}"} \
    archive
  echo "Exporting $scheme (destination export, method app-store-connect)"
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_path" \
    -exportOptionsPlist "$opts" -allowProvisioningUpdates \
    ${AUTH[@]+"${AUTH[@]}"}
}

# Fail fast if the IPA was not built with the iOS 26 SDK or later.
verify_ios_ipa() {
  local ipa="$1"
  local tmp app sdk
  tmp="$(mktemp -d)"
  unzip -q -o "$ipa" -d "$tmp"
  app="$(find "$tmp/Payload" -name '*.app' -maxdepth 1 | head -1)"
  if [ -z "$app" ]; then
    echo "verify: no app in $ipa" >&2
    rm -rf "$tmp"
    return 1
  fi
  sdk="$(plutil -extract DTSDKName raw -- "$app/Info.plist" 2>/dev/null || true)"
  echo "iOS IPA $(basename "$ipa"): DTSDKName=${sdk:-unknown}"
  codesign -dv --verbose=2 "$app" 2>&1 | sed 's/^/  /' || true
  case "$sdk" in
    iphoneos26*|iphoneos2[7-9]*|iphoneos[3-9]*)
      rm -rf "$tmp"
      return 0
      ;;
    *)
      echo "iOS IPA was built with SDK '${sdk:-unknown}'; App Store Connect requires the iOS 26 SDK or later (Xcode 26+)." >&2
      rm -rf "$tmp"
      return 1
      ;;
  esac
}

# Confirm the exported macOS product is a distribution-signed installer pkg,
# not an ad-hoc "Sign to Run Locally" archive leftover.
verify_macos_pkg() {
  local pkg="$1"
  local info
  echo "macOS pkg $(basename "$pkg") signature:"
  info="$(pkgutil --check-signature "$pkg" 2>&1)" || true
  echo "$info" | sed 's/^/  /'
  if echo "$info" | grep -qiE 'not signed|untrusted|Sign to Run Locally|ad-?hoc'; then
    echo "macOS pkg is not distribution-signed." >&2
    return 1
  fi
  if ! echo "$info" | grep -qiE 'Mac Installer Distribution|3rd Party Mac Developer Installer'; then
    echo "macOS pkg is not signed with Mac Installer Distribution (or 3rd Party Mac Developer Installer)." >&2
    return 1
  fi
}

upload_one() {
  local file="$1"
  local type="$2"
  if [ ! -f "$file" ]; then
    echo "upload: missing $file" >&2
    return 1
  fi
  echo "Uploading $(basename "$file") to App Store Connect with altool (type $type). This does not submit for review."
  xcrun altool --upload-app -f "$file" -t "$type" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
}

if [ "$PLATFORM" = "ios" ] || [ "$PLATFORM" = "both" ]; then
  archive_one TrilliumIOS "generic/platform=iOS" \
    "$OUT/Trillium-iOS-$VERSION-$BUILD.xcarchive" \
    "$OUT/export-ios" "$IOS_OPTS"
  ipa_out="$(ls "$OUT"/export-ios/*.ipa 2>/dev/null | head -1 || true)"
  if [ -z "${ipa_out:-}" ]; then
    echo "export produced no iOS IPA in $OUT/export-ios" >&2
    exit 1
  fi
  ls "$ipa_out"
  verify_ios_ipa "$ipa_out"
fi
if [ "$PLATFORM" = "macos" ] || [ "$PLATFORM" = "both" ]; then
  archive_one TrilliumMac "generic/platform=macOS" \
    "$OUT/Trillium-macOS-$VERSION-$BUILD.xcarchive" \
    "$OUT/export-macos" "$MAC_OPTS"
  pkg_out="$(ls "$OUT"/export-macos/*.pkg 2>/dev/null | head -1 || true)"
  if [ -z "${pkg_out:-}" ]; then
    pkg_out="$(ls "$OUT"/export-macos/*.ipa 2>/dev/null | head -1 || true)"
  fi
  if [ -z "${pkg_out:-}" ]; then
    echo "export produced no macOS pkg (or IPA) in $OUT/export-macos" >&2
    exit 1
  fi
  ls "$pkg_out"
  case "$pkg_out" in
    *.pkg) verify_macos_pkg "$pkg_out" ;;
    *)
      echo "macOS export is $(basename "$pkg_out"), not a Mac Installer Distribution pkg." >&2
      exit 1
      ;;
  esac
fi

if [ "$UPLOAD" = 1 ]; then
  install_altool_key
  upload_status=0
  if [ "$PLATFORM" = "ios" ] || [ "$PLATFORM" = "both" ]; then
    ipa=$(ls "$OUT"/export-ios/*.ipa 2>/dev/null | head -1)
    if ! upload_one "$ipa" ios; then
      upload_status=1
    fi
  fi
  if [ "$PLATFORM" = "macos" ] || [ "$PLATFORM" = "both" ]; then
    pkg=$(ls "$OUT"/export-macos/*.pkg 2>/dev/null | head -1)
    if [ -z "${pkg:-}" ]; then
      pkg=$(ls "$OUT"/export-macos/*.ipa 2>/dev/null | head -1)
    fi
    if ! upload_one "$pkg" macos; then
      upload_status=1
    fi
  fi
  if [ "$upload_status" -ne 0 ]; then
    echo "One or more TestFlight uploads failed (not submitted for review)." >&2
    exit "$upload_status"
  fi
else
  echo "Not uploaded. Re-run with UPLOAD=1 and an API key to upload for TestFlight, or use Xcode Organizer / Transporter."
fi
