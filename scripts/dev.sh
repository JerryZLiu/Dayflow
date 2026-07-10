#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

APP_NAME=${APP_NAME:-Dayflow}
BUNDLE_ID=${BUNDLE_ID:-teleportlabs.com.Dayflow}
PROJECT=${PROJECT:-"$REPO_ROOT/Dayflow/Dayflow.xcodeproj"}
SCHEME=${SCHEME:-Dayflow}
CONFIG=${CONFIG:-Debug}
DERIVED_DATA=${DERIVED_DATA:-"$REPO_ROOT/build/dev"}
DESTINATION=${DESTINATION:-platform=macOS,arch=arm64}
INSTALL_PATH=${INSTALL_PATH:-"/Applications/$APP_NAME.app"}
APP_PATH="$DERIVED_DATA/Build/Products/$CONFIG/$APP_NAME.app"
STABLE_REQUIREMENT="=designated => identifier \"$BUNDLE_ID\""

usage() {
  cat <<EOF
Usage: scripts/dev.sh <command>

Commands:
  doctor   Check the local Xcode development environment.
  build    Build a locally signed Debug app.
  test     Run the Dayflow unit tests.
  install  Build, replace /Applications/Dayflow.app, and launch it.
  open     Launch the installed app.

Environment overrides: DERIVED_DATA, DESTINATION, INSTALL_PATH, CONFIG.
EOF
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Missing required command: $1" >&2
    exit 1
  }
}

designated_requirement() {
  local app=$1
  codesign -dr - "$app" 2>&1 | sed -n 's/^# designated => //p'
}

sign_with_stable_local_identity() {
  codesign --force \
    --sign - \
    --preserve-metadata=entitlements,flags,runtime \
    --requirements "$STABLE_REQUIREMENT" \
    "$APP_PATH"
  codesign --verify --deep --strict "$APP_PATH"
}

build_app() {
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    DEVELOPMENT_TEAM=

  [[ -d "$APP_PATH" ]] || {
    echo "ERROR: Built app not found at $APP_PATH" >&2
    exit 1
  }
  sign_with_stable_local_identity
}

run_tests() {
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -only-testing:DayflowTests \
    CODE_SIGNING_ALLOWED=NO
}

quit_installed_app() {
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
  for _ in {1..20}; do
    pgrep -f "$INSTALL_PATH/Contents/MacOS/$APP_NAME" >/dev/null || return
    sleep 0.25
  done
  pkill -TERM -f "$INSTALL_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null || true
}

install_app() {
  build_app

  local old_requirement=""
  local new_requirement
  if [[ -d "$INSTALL_PATH" ]]; then
    old_requirement=$(designated_requirement "$INSTALL_PATH" || true)
  fi
  new_requirement=$(designated_requirement "$APP_PATH")

  quit_installed_app
  rm -rf "$INSTALL_PATH"
  ditto --noextattr --norsrc "$APP_PATH" "$INSTALL_PATH"
  xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$INSTALL_PATH"
  codesign --verify --deep --strict "$INSTALL_PATH"

  if [[ -n "$old_requirement" && "$old_requirement" != "$new_requirement" ]]; then
    echo "Local signing identity changed; resetting stale screen-capture approval once."
    tccutil reset ScreenCapture "$BUNDLE_ID"
  fi

  open -a "$INSTALL_PATH"
  echo "Installed and launched $INSTALL_PATH"
}

doctor() {
  require xcodebuild
  require codesign
  require ditto
  require tccutil
  [[ -d "$PROJECT" ]] || {
    echo "ERROR: Xcode project not found at $PROJECT" >&2
    exit 1
  }
  xcodebuild -version
  echo "Project:      $PROJECT"
  echo "DerivedData:  $DERIVED_DATA"
  echo "Install path: $INSTALL_PATH"
  echo "Bundle ID:    $BUNDLE_ID"
}

case "${1:-}" in
  doctor) doctor ;;
  build) build_app ;;
  test) run_tests ;;
  install) install_app ;;
  open) open -a "$INSTALL_PATH" ;;
  *) usage; exit 1 ;;
esac
