#!/usr/bin/env bash
# Install the super-pro agent skill stack globally for Cursor Cloud Agents.
# Idempotent: safe to re-run. Skills install to ~/.agents/skills (not the repo).
#
# Usage:
#   bash scripts/install-super-pro-skills.sh [options]
#
# Options:
#   --skip-optional   Skip cloud/vendor packs (supabase, cloudflare, aws)
#   --no-aws          Skip AWS selective pack
#   --with-gstack     Clone/setup gstack and link into ~/.agents/skills (default: on)
#   --no-gstack       Skip gstack install
#   --with-tools      Install agent-browser CLI and specify-cli
#   -h, --help        Show help

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SKIP_OPTIONAL=false
WITH_AWS=true
WITH_GSTACK=true
WITH_TOOLS=false

SKILLS=(npx --yes skills@latest add)

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-optional) SKIP_OPTIONAL=true; WITH_AWS=false ;;
    --no-aws) WITH_AWS=false ;;
    --with-gstack) WITH_GSTACK=true ;;
    --no-gstack) WITH_GSTACK=false ;;
    --with-tools) WITH_TOOLS=true ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

log() { echo "[install-super-pro] $*"; }

install_pack() {
  local repo="$1"
  shift
  log "Installing ${repo} ..."
  "${SKILLS[@]}" "$repo" "$@" -g -a cursor -y
}

install_pack_all() {
  install_pack "$1" --skill '*'
}

install_pack_select() {
  local repo="$1"
  shift
  local args=()
  for skill in "$@"; do
    args+=(--skill "$skill")
  done
  install_pack "$repo" "${args[@]}"
}

ensure_path() {
  export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:${HOME}/.bun/bin:${PATH}"
}

install_tools() {
  ensure_path
  log "Installing runtime tools (agent-browser, specify-cli) ..."

  if ! command -v agent-browser >/dev/null 2>&1; then
    mkdir -p "${HOME}/.npm-global"
    npm config set prefix "${HOME}/.npm-global"
    npm install -g agent-browser
    agent-browser install || true
  else
    log "agent-browser already installed"
  fi

  if ! command -v specify >/dev/null 2>&1; then
    if ! command -v uv >/dev/null 2>&1; then
      curl -LsSf https://astral.sh/uv/install.sh | sh
      # shellcheck disable=SC1091
      [[ -f "${HOME}/.local/bin/env" ]] && source "${HOME}/.local/bin/env"
    fi
    uv tool install specify-cli --from git+https://github.com/github/spec-kit.git
  else
    log "specify-cli already installed"
  fi
}

install_gstack() {
  bash "${ROOT}/scripts/install-gstack-skills.sh"
}

main() {
  ensure_path
  log "Starting super-pro skill stack install (global, Cursor)"
  log "Manifest: ${ROOT}/.agents/super-pro-packs.json"
  log "Docs: ${ROOT}/docs/super-pro-stack.md"

  # Layer 1: Discover (install first)
  install_pack_select vercel-labs/skills find-skills

  # Core S-tier packs
  install_pack_all trailofbits/skills
  install_pack_select vercel-labs/agent-browser agent-browser
  install_pack_all anthropics/skills
  install_pack_all github/awesome-copilot
  install_pack_select microsoft/skills \
    continual-learning \
    frontend-design-review \
    github-issue-creator \
    mcp-builder \
    skill-creator \
    copilot-sdk \
    microsoft-docs \
    cloud-solution-architect
  install_pack_all EveryInc/compound-engineering-plugin
  install_pack_select shadcn/improve improve
  install_pack_all mattpocock/skills
  install_pack_all obra/superpowers
  install_pack_all addyosmani/agent-skills
  install_pack_all vercel-labs/agent-skills

  # A-tier / methodology packs
  install_pack_all forrestchang/andrej-karpathy-skills
  install_pack_all brainqub3/red-green-refactor
  install_pack_select jwynia/agent-skills security-scan dependency-scan config-scan
  install_pack_select pproenca/dot-skills tdd

  # Optional cloud/vendor packs
  if [[ "$SKIP_OPTIONAL" == false ]]; then
    install_pack_all supabase/agent-skills
    install_pack_all cloudflare/skills
  else
    log "Skipping optional cloud packs (--skip-optional)"
  fi

  if [[ "$WITH_AWS" == true ]]; then
    install_pack_select aws/agent-toolkit-for-aws \
      aws-billing-and-cost-management \
      aws-security \
      aws-serverless \
      aws-observability \
      aws-iam \
      aws-cdk
  else
    log "Skipping AWS pack (--no-aws or --skip-optional)"
  fi

  if [[ "$WITH_TOOLS" == true ]]; then
    install_tools
  fi

  if [[ "$WITH_GSTACK" == true ]]; then
    install_gstack
  fi

  log "Done. Global lock: ${HOME}/.agents/.skill-lock.json"
  log "For full PraxStack (OpenSpec, Graphify, Stitch, etc.): bash scripts/install-praxstack-skills.sh --skip-super-pro"
  log "Verify with: bash scripts/verify-super-pro-skills.sh"
}

main "$@"
