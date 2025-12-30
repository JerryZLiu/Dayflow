#!/usr/bin/env bash
set -euo pipefail

# Release helper for Dayflow: builds, signs, notarizes, and packages a DMG for distribution.
#
# Usage:
#   ./scripts/release_dmg.sh
#
# Optional env vars:
#   SCHEME           - Xcode scheme (default: Dayflow)
#   CONFIG           - Xcode configuration (default: Release)
#   DERIVED_DATA     - Derived data path (default: build)
#   APP_NAME         - App name (default: Dayflow)
#   ENTITLEMENTS     - Entitlements plist path (default: Dayflow/Dayflow/Dayflow.entitlements)
#   SIGN_ID          - Codesign identity (e.g. "Developer ID Application: Your Name (TEAMID)")
#   VOL_NAME         - DMG volume name (defaults to APP_NAME)
#   DMG_NAME         - Output DMG name (defaults to "${APP_NAME}.dmg")
#   NOTARY_PROFILE   - Saved notarytool keychain profile (optional)
#   NOTARY_APPLE_ID  - Apple ID for notarytool (optional)
#   NOTARY_TEAM_ID   - Team ID for notarytool (optional)
#   NOTARY_APP_PASSWORD - App-specific password for Apple ID (optional)
#   ASC_KEY_ID       - App Store Connect API key ID (optional)
#   ASC_ISSUER_ID    - App Store Connect Issuer ID (optional)
#   ASC_P8_PATH      - Path to .p8 private key (optional)

# Load optional per-developer config
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "${SCRIPT_DIR}/release.env" ]]; then
  # shellcheck disable=SC1090
  source "${SCRIPT_DIR}/release.env"
fi

SCHEME=${SCHEME:-Dayflow}
CONFIG=${CONFIG:-Release}
DERIVED_DATA=${DERIVED_DATA:-build}
APP_NAME=${APP_NAME:-Dayflow}
ENTITLEMENTS=${ENTITLEMENTS:-Dayflow/Dayflow/Dayflow.entitlements}
VOL_NAME=${VOL_NAME:-$APP_NAME}
DMG_NAME=${DMG_NAME:-"${APP_NAME}.dmg"}

APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIG}/${APP_NAME}.app"
# Work in a non-iCloud temporary directory to avoid fileprovider xattrs
SANITIZED_DIR=${SANITIZED_DIR:-$(mktemp -d -t dayflow_sign)}
trap 'rm -rf "${SANITIZED_DIR}"' EXIT
SANITIZED_APP="${SANITIZED_DIR}/${APP_NAME}.app"

# Fixed project location inside repo
PROJECT_PATH=${PROJECT_PATH:-Dayflow/Dayflow.xcodeproj}
if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "ERROR: Xcode project not found at $PROJECT_PATH" >&2
  exit 1
fi

echo "[1/7] Building ${APP_NAME} (${SCHEME}|${CONFIG}) using project ${PROJECT_PATH} with code signing disabled…"
xcodebuild \
  -project "${PROJECT_PATH}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "${APP_PATH}" ]]; then
  echo "ERROR: Built app not found at ${APP_PATH}" >&2
  exit 1
fi

echo "[2/8] Uploading dSYM to Sentry for crash symbolication…"
if [[ -n "${SENTRY_AUTH_TOKEN:-}" && -n "${SENTRY_ORG:-}" && -n "${SENTRY_PROJECT:-}" ]]; then
  if ! command -v sentry-cli >/dev/null 2>&1; then
    echo "WARNING: sentry-cli not found. Install with: brew install getsentry/tools/sentry-cli" >&2
    echo "         Skipping dSYM upload. Crash reports will not be symbolicated." >&2
  else
    # Find the dSYM bundle in DerivedData
    DSYM_PATH="${DERIVED_DATA}/Build/Products/${CONFIG}/${APP_NAME}.app.dSYM"
    if [[ -d "${DSYM_PATH}" ]]; then
      # Get version and build number from Info.plist
      VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "unknown")
      BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "unknown")
      RELEASE="${VERSION}+${BUILD}"

      echo "Uploading dSYM for release ${RELEASE} to ${SENTRY_ORG}/${SENTRY_PROJECT}..."
      SENTRY_AUTH_TOKEN="${SENTRY_AUTH_TOKEN}" sentry-cli upload-dif \
        --org "${SENTRY_ORG}" \
        --project "${SENTRY_PROJECT}" \
        "${DSYM_PATH}"

      echo "✓ dSYM uploaded successfully"
    else
      echo "WARNING: dSYM not found at ${DSYM_PATH}" >&2
      echo "         Check that DEBUG_INFORMATION_FORMAT is set to 'dwarf-with-dsym' in build settings." >&2
    fi
  fi
else
  echo "Skipping dSYM upload: SENTRY_AUTH_TOKEN, SENTRY_ORG, or SENTRY_PROJECT not set"
  echo "Add these to scripts/release.env to enable crash symbolication"
fi

echo "[3/8] Determining Developer ID signing identity…"
SIGN_ID=${SIGN_ID:-}
if [[ -z "${SIGN_ID}" ]]; then
  # Try to pick the first available Developer ID Application identity.
  SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Developer ID Application/ {print $2; exit}') || true
fi
if [[ -z "${SIGN_ID}" ]]; then
  echo "ERROR: No Developer ID Application identity found. Set SIGN_ID env or import certificate." >&2
  security find-identity -v -p codesigning || true
  exit 1
fi
echo "Using signing identity: ${SIGN_ID}"

echo "[4/8] Creating sanitized copy for signing…"
rm -rf "${SANITIZED_DIR}"
mkdir -p "${SANITIZED_DIR}"
# Copy without extended attributes or resource forks
ditto --noextattr --norsrc "${APP_PATH}" "${SANITIZED_APP}"

echo "[5/8] Codesigning (no --deep, proper Sparkle helpers)…"
# Ensure any stray metadata is gone
rm -f "${SANITIZED_APP}"/Icon? 2>/dev/null || true
find -L "${SANITIZED_APP}" -name ".DS_Store" -delete || true
if command -v xattr >/dev/null 2>&1; then
  xattr -rc "${SANITIZED_APP}" 2>/dev/null || true
fi

# Re-sign Sparkle helpers first per Sparkle sandboxing guide
SPARKLE_DIR="${SANITIZED_APP}/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "${SPARKLE_DIR}" ]]; then
  if [[ -d "${SPARKLE_DIR}/XPCServices/Installer.xpc" ]]; then
    codesign -vvv --force -o runtime --sign "${SIGN_ID}" \
      "${SPARKLE_DIR}/XPCServices/Installer.xpc"
  fi
  if [[ -d "${SPARKLE_DIR}/XPCServices/Downloader.xpc" ]]; then
    # Preserve the XPC's own entitlements
    codesign -vvv --force -o runtime --preserve-metadata=entitlements --sign "${SIGN_ID}" \
      "${SPARKLE_DIR}/XPCServices/Downloader.xpc"
  fi
  if [[ -f "${SPARKLE_DIR}/Autoupdate" ]]; then
    codesign -vvv --force -o runtime --sign "${SIGN_ID}" \
      "${SPARKLE_DIR}/Autoupdate"
  fi
  if [[ -d "${SPARKLE_DIR}/Updater.app" ]]; then
    codesign -vvv --force -o runtime --sign "${SIGN_ID}" \
      "${SPARKLE_DIR}/Updater.app"
  fi
  # Finally sign the framework container itself
  codesign -vvv --force -o runtime --sign "${SIGN_ID}" \
    "${SPARKLE_DIR}/../../Current" 2>/dev/null || \
  codesign -vvv --force -o runtime --sign "${SIGN_ID}" \
    "${SPARKLE_DIR}"
fi

# Re-sign Sentry framework to ensure proper resource sealing
SENTRY_DIR="${SANITIZED_APP}/Contents/Frameworks/Sentry.framework"
if [[ -d "${SENTRY_DIR}" ]]; then
  # Sign the versioned framework (handles both Current symlink and direct path)
  codesign -vvv --force -o runtime --sign "${SIGN_ID}" \
    "${SENTRY_DIR}/Versions/Current" 2>/dev/null || \
  codesign -vvv --force -o runtime --sign "${SIGN_ID}" \
    "${SENTRY_DIR}"
fi

# Inject analytics and crash reporting keys (optional) before final app signing
if [[ -n "${POSTHOG_API_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :PHPostHogApiKey ${POSTHOG_API_KEY}" "${SANITIZED_APP}/Contents/Info.plist" \
    >/dev/null 2>&1 || /usr/libexec/PlistBuddy -c "Add :PHPostHogApiKey string ${POSTHOG_API_KEY}" "${SANITIZED_APP}/Contents/Info.plist"
fi
if [[ -n "${POSTHOG_HOST:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :PHPostHogHost ${POSTHOG_HOST}" "${SANITIZED_APP}/Contents/Info.plist" \
    >/dev/null 2>&1 || /usr/libexec/PlistBuddy -c "Add :PHPostHogHost string ${POSTHOG_HOST}" "${SANITIZED_APP}/Contents/Info.plist"
fi
if [[ -n "${SENTRY_DSN:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SentryDSN ${SENTRY_DSN}" "${SANITIZED_APP}/Contents/Info.plist" \
    >/dev/null 2>&1 || /usr/libexec/PlistBuddy -c "Add :SentryDSN string ${SENTRY_DSN}" "${SANITIZED_APP}/Contents/Info.plist"
fi
if [[ -n "${SENTRY_ENV:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SentryEnvironment ${SENTRY_ENV}" "${SANITIZED_APP}/Contents/Info.plist" \
    >/dev/null 2>&1 || /usr/libexec/PlistBuddy -c "Add :SentryEnvironment string ${SENTRY_ENV}" "${SANITIZED_APP}/Contents/Info.plist"
fi

# Copy entitlements for codesigning
RESOLVED_ENTS="${SANITIZED_DIR}/resolved.entitlements"
cp "${ENTITLEMENTS}" "${RESOLVED_ENTS}"

# Now sign the top-level app bundle (no --deep), using resolved entitlements
codesign -vvv --force --strict \
  --options runtime \
  --timestamp \
  --entitlements "${RESOLVED_ENTS}" \
  --sign "${SIGN_ID}" \
  "${SANITIZED_APP}"


echo "[6/8] Verifying signature…"
codesign --verify --deep --strict --verbose=2 "${SANITIZED_APP}"
spctl -a -vvv --type execute "${SANITIZED_APP}" || true

echo "[7/8] Creating DMG with create-dmg…"
# Require create-dmg for reliable DMG styling
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "ERROR: create-dmg is required but not installed." >&2
  echo "       Install it with: brew install create-dmg" >&2
  exit 1
fi

# Default to project's background image
SCRIPT_PARENT=$(cd "$SCRIPT_DIR/.." && pwd)
DEFAULT_BG="${SCRIPT_PARENT}/docs/assets/dmg-background.png"
DMG_BG=${DMG_BG:-$DEFAULT_BG}

if [[ ! -f "${DMG_BG}" ]]; then
  echo "ERROR: Background image not found at ${DMG_BG}" >&2
  exit 1
fi

rm -f "${DMG_NAME}"

# Window size and positions tuned for docs/assets/dmg-background.png (1550×960 @2x, displays as 775×480)
# Dayflow app on left, Applications folder on right (swapped from typical layout)
create-dmg \
  --volname "${VOL_NAME}" \
  --background "${DMG_BG}" \
  --window-size 775 480 \
  --icon-size "${DMG_ICON_SIZE:-128}" \
  --icon "${APP_NAME}.app" 200 270 \
  --app-drop-link 575 270 \
  --no-internet-enable \
  "${DMG_NAME}" \
  "${SANITIZED_APP}"

echo "[8/8] Submitting DMG for notarization…"
NOTARY_ARGS=("${DMG_NAME}")
if [[ "${NO_NOTARIZE:-0}" == "1" ]]; then
  echo "Skipping notarization: NO_NOTARIZE=1"
  NOTARY_ARGS=()
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "Using keychain profile: ${NOTARY_PROFILE}"
  NOTARY_ARGS=(submit "${DMG_NAME}" --keychain-profile "${NOTARY_PROFILE}" --wait)
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_APP_PASSWORD:-}" ]]; then
  echo "Using Apple ID credentials for notarytool"
  NOTARY_ARGS=(submit "${DMG_NAME}" --apple-id "${NOTARY_APPLE_ID}" --team-id "${NOTARY_TEAM_ID}" --password "${NOTARY_APP_PASSWORD}" --wait)
elif [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_P8_PATH:-}" ]]; then
  echo "Using App Store Connect API key for notarytool"
  NOTARY_ARGS=(submit "${DMG_NAME}" --key "${ASC_P8_PATH}" --key-id "${ASC_KEY_ID}" --issuer "${ASC_ISSUER_ID}" --wait)
else
  echo "Skipping notarization: no credentials provided (set NOTARY_PROFILE or Apple ID or ASC_* env)."
  NOTARY_ARGS=()
fi

if [[ ${#NOTARY_ARGS[@]} -gt 0 ]]; then
  xcrun notarytool "${NOTARY_ARGS[@]}"
echo "[8/8] Stapling notarization ticket…"
  xcrun stapler staple "${DMG_NAME}"
  xcrun stapler validate "${DMG_NAME}"
else
  echo "NOTE: DMG was NOT notarized. Provide credentials to notarize."
fi

echo "Done. Output: ${DMG_NAME}"
