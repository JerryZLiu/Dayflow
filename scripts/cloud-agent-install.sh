#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v swift >/dev/null 2>&1; then
  if [[ -f /opt/swiftly/bin/swiftly ]]; then
    export PATH="/opt/swiftly/bin:${PATH}"
  elif [[ -f "${HOME}/.local/share/swiftly/env.sh" ]]; then
    # shellcheck disable=SC1091
    source "${HOME}/.local/share/swiftly/env.sh"
  fi
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is not installed. The Cloud Agent base image should include the Swift toolchain." >&2
  exit 1
fi

echo "[install] Building dayflow-cli (release)..."
swift build -c release --package-path tools/dayflow-cli

echo "[install] Creating CLI fixture database..."
bash tools/dayflow-cli/fixtures/create_fixture_db.sh

echo "[install] Linking dayflow into .cursor/bin..."
mkdir -p .cursor/bin
ln -sf "$ROOT/tools/dayflow-cli/.build/release/dayflow" .cursor/bin/dayflow

echo "[install] Done."
