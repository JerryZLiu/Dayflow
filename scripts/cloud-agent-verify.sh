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

DAYFLOW_BIN="${DAYFLOW_BIN:-$ROOT/.cursor/bin/dayflow}"
FIXTURE_DB="$ROOT/tools/dayflow-cli/fixtures/chunks.sqlite"

if [[ ! -x "$DAYFLOW_BIN" ]]; then
  DAYFLOW_BIN="$ROOT/tools/dayflow-cli/.build/release/dayflow"
fi

if [[ ! -x "$DAYFLOW_BIN" ]]; then
  echo "dayflow binary not found. Run scripts/cloud-agent-install.sh first." >&2
  exit 1
fi

if [[ ! -f "$FIXTURE_DB" ]]; then
  echo "Fixture database missing at $FIXTURE_DB" >&2
  exit 1
fi

export DAYFLOW_DB="$FIXTURE_DB"

echo "[verify] swift --version"
swift --version

echo "[verify] dayflow status --json"
"$DAYFLOW_BIN" status --json | python3 -m json.tool >/dev/null

echo "[verify] dayflow timeline 2026-03-11 --json"
timeline_json="$("$DAYFLOW_BIN" timeline 2026-03-11 --json)"
echo "$timeline_json" | python3 -m json.tool >/dev/null
card_count="$(echo "$timeline_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("cards", [])))')"
if [[ "$card_count" -lt 2 ]]; then
  echo "Expected at least 2 timeline cards, got $card_count" >&2
  exit 1
fi

echo "[verify] dayflow search CLI --json"
search_json="$("$DAYFLOW_BIN" search CLI --json)"
echo "$search_json" | python3 -m json.tool >/dev/null

echo "[verify] dayflow daily 2026-03-11 --json"
"$DAYFLOW_BIN" daily 2026-03-11 --json | python3 -m json.tool >/dev/null

echo "[verify] dayflow categories"
"$DAYFLOW_BIN" categories >/dev/null

echo "[verify] All checks passed."
