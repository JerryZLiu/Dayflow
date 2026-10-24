#!/usr/bin/env bash
# Verify the PraxStack / super-pro agent skill stack is installed globally.
# Exit 0 if all checks pass; exit 1 on any failure.
#
# Usage: bash scripts/verify-super-pro-skills.sh [--skip-optional]

set -euo pipefail

SKIP_OPTIONAL=false
for arg in "$@"; do
  case "$arg" in
    --skip-optional) SKIP_OPTIONAL=true ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:${PATH}"

PASS=0
FAIL=0
WARN=0

ok()   { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*" >&2; FAIL=$((FAIL + 1)); }
warn() { echo "  ⚠ $*"; WARN=$((WARN + 1)); }

check_skill() {
  local name="$1"
  if [[ -f "${HOME}/.agents/skills/${name}/SKILL.md" ]]; then
    ok "skill: ${name}"
  else
    fail "skill missing: ${name} (~/.agents/skills/${name}/SKILL.md)"
  fi
}

check_cmd() {
  local cmd="$1"
  local label="${2:-$1}"
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "command: ${label}"
  else
    fail "command missing: ${label}"
  fi
}

echo "[verify-praxstack] Checking manifest exists ..."
if [[ -f "${ROOT}/.agents/super-pro-packs.json" ]]; then
  ok "manifest: .agents/super-pro-packs.json"
else
  fail "manifest missing: .agents/super-pro-packs.json"
fi

echo "[verify-praxstack] Checking core discover/implement skills ..."
check_skill find-skills
check_skill improve
check_skill test-driven-development
check_skill code-review
check_skill ce-code-review
check_skill agent-browser
check_skill karpathy-guidelines
check_skill red-green-refactor
check_skill tdd
check_skill security-scan
if [[ "${SKIP_OPTIONAL}" != true ]]; then
  check_skill supabase
  check_skill cloudflare
  check_skill aws-security
else
  echo "[verify-praxstack] Skipping optional cloud/vendor packs (--skip-optional)"
fi

echo "[verify-praxstack] Checking Prax personal workflow (skills-and-personas) ..."
PRAXSTACK_SKILLS=(
  kingmode
  apex-autonomous-mode
  techtutor
  chronicle
  teach-pro-max
  constellation-team
  blueprint-creator
  superimprove
  backend-pe
  product-manager
  principal-engineer
)
for s in "${PRAXSTACK_SKILLS[@]}"; do
  check_skill "$s"
done

if [[ -f "${HOME}/.agents/.skills-and-personas.json" ]]; then
  ok "manifest stamp: ~/.agents/.skills-and-personas.json"
else
  warn "skills-and-personas stamp missing (run install-praxstack-personas.sh)"
fi

if [[ -L "${HOME}/.agents/personas/personas" ]] || [[ -d "${HOME}/.agents/personas/personas" ]]; then
  ok "personas: ~/.agents/personas/personas"
else
  warn "personas not linked (run install-praxstack-personas.sh)"
fi

echo "[verify-praxstack] Checking PraxStack extension skills ..."
check_skill last30days
check_skill deep-research
check_skill hallmark
check_skill impeccable
check_skill web-design-guidelines
check_skill remotion-best-practices
check_skill stitch-generate-design
check_skill api-design-principles
check_skill nvidia-skill-finder

echo "[verify-praxstack] Checking OpenSpec skills ..."
check_skill openspec-propose
check_skill openspec-apply-change

echo "[verify-praxstack] Checking gstack skills ..."
check_skill plan-ceo-review
check_skill office-hours
check_skill review
check_skill qa
check_skill ship

echo "[verify-praxstack] Checking slash-command targets (key workflows) ..."
SLASH_CHECKS=(
  plan-ceo-review
  find-skills
  improve
  office-hours
  review
  qa
  ship
  openspec-propose
  impeccable
  last30days
  deep-research
  hallmark
  web-design-guidelines
  kingmode
  teach-pro-max
  chronicle
  apex-autonomous-mode
)
for s in "${SLASH_CHECKS[@]}"; do
  if [[ -f "${HOME}/.agents/skills/${s}/SKILL.md" ]]; then
    ok "slash: /${s}"
  else
    fail "slash missing: /${s}"
  fi
done

echo "[verify-praxstack] Checking tools (optional) ..."
if command -v agent-browser >/dev/null 2>&1; then
  ok "agent-browser CLI"
else
  warn "agent-browser CLI not in PATH (run install with --with-tools)"
fi

if command -v specify >/dev/null 2>&1; then
  ok "specify CLI"
else
  warn "specify CLI not in PATH (run install with --with-tools)"
fi

if command -v openspec >/dev/null 2>&1; then
  ok "openspec CLI"
else
  warn "openspec CLI not in PATH"
fi

if command -v graphify >/dev/null 2>&1; then
  ok "graphify CLI"
else
  warn "graphify CLI not in PATH"
fi

echo "[verify-praxstack] Checking Context7 MCP config ..."
if [[ -f "${HOME}/.cursor/mcp.json" ]] && grep -q '"context7"' "${HOME}/.cursor/mcp.json" 2>/dev/null; then
  ok "Context7 in ~/.cursor/mcp.json"
else
  warn "Context7 not in ~/.cursor/mcp.json"
fi

echo "[verify-praxstack] Checking skills CLI ..."
check_cmd npx "npx (skills CLI)"

if npx --yes skills@latest list -g >/dev/null 2>&1; then
  ok "skills list -g"
else
  fail "skills list -g failed"
fi

echo "[verify-praxstack] Checking global lock ..."
if [[ -f "${HOME}/.agents/.skill-lock.json" ]]; then
  ok "global lock: ~/.agents/.skill-lock.json"
else
  warn "no global lock yet (run install-praxstack-skills.sh)"
fi

SKILL_COUNT=$(find "${HOME}/.agents/skills" -maxdepth 2 -name 'SKILL.md' 2>/dev/null | wc -l | tr -d ' ')
DIR_COUNT=$(find "${HOME}/.agents/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
echo "[verify-praxstack] Installed skill dirs: ${DIR_COUNT}, SKILL.md files: ${SKILL_COUNT}"
if [[ "${SKILL_COUNT}" -ge 700 ]]; then
  ok "skill count >= 700 (${SKILL_COUNT})"
else
  warn "low skill count (${SKILL_COUNT}); run bash scripts/install-praxstack-skills.sh"
fi

echo ""
echo "[verify-praxstack] Results: ${PASS} passed, ${FAIL} failed, ${WARN} warnings"

if [[ "${FAIL}" -gt 0 ]]; then
  echo "[verify-praxstack] FAILED" >&2
  exit 1
fi

echo "[verify-praxstack] PASSED"
exit 0
