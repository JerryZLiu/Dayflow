#!/usr/bin/env bash
# Install the full PraxStack skill ecosystem for Cursor Cloud Agents.
# Extends super-pro stack with OpenSpec, Graphify, Impeccable, Stitch, Remotion,
# last30days, agent-deep-research, Hallmark, selective wshobson/nvidia packs, etc.
#
# Skills install globally to ~/.agents/skills (Cloud Agent discovery path).
# Idempotent: safe to re-run.
#
# Usage:
#   bash scripts/install-praxstack-skills.sh [options]
#
# Options:
#   --skip-super-pro    Skip base super-pro install (only add PraxStack extensions)
#   --skip-optional     Skip optional cloud/vendor packs in super-pro
#   --no-gstack         Skip gstack clone/setup
#   --with-tools        Install agent-browser, specify-cli, openspec, graphify
#   -h, --help          Show help

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SKIP_SUPER_PRO=false
SKIP_OPTIONAL=false
WITH_GSTACK=true
WITH_TOOLS=false

SKILLS=(npx --yes skills@latest add)

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-super-pro) SKIP_SUPER_PRO=true ;;
    --skip-optional) SKIP_OPTIONAL=true ;;
    --no-gstack) WITH_GSTACK=false ;;
    --with-tools) WITH_TOOLS=true ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

log() { echo "[install-praxstack] $*"; }

ensure_path() {
  export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:${HOME}/.bun/bin:${PATH}"
}

install_pack() {
  local repo="$1"
  shift
  log "Installing ${repo} ..."
  "${SKILLS[@]}" "$repo" "$@" -g -a cursor -y
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

install_super_pro() {
  local args=()
  if [[ "$SKIP_OPTIONAL" == true ]]; then
    args+=(--skip-optional)
  fi
  if [[ "$WITH_GSTACK" == false ]]; then
    args+=(--no-gstack)
  fi
  if [[ "$WITH_TOOLS" == true ]]; then
    args+=(--with-tools)
  fi
  bash "${ROOT}/scripts/install-super-pro-skills.sh" "${args[@]}"
}

install_openspec_global() {
  ensure_path
  if ! command -v openspec >/dev/null 2>&1; then
    log "Installing @fission-ai/openspec globally ..."
    mkdir -p "${HOME}/.npm-global"
    npm config set prefix "${HOME}/.npm-global"
    npm install -g @fission-ai/openspec
  else
    log "openspec already installed"
  fi

  if [[ ! -f "${ROOT}/openspec/config.yaml" ]]; then
    log "Initializing OpenSpec in repo ..."
    (cd "${ROOT}" && openspec init --tools cursor --language en)
  else
    log "OpenSpec already initialized in repo"
  fi

  # Link project openspec skills into ~/.agents/skills for Cloud Agent discovery
  if [[ -d "${ROOT}/.cursor/skills" ]]; then
    for skill_dir in "${ROOT}/.cursor/skills"/*/; do
      [[ -d "${skill_dir}" ]] || continue
      [[ -f "${skill_dir}/SKILL.md" ]] || continue
      local name
      name="$(basename "${skill_dir}")"
      ln -sfn "${skill_dir}" "${HOME}/.agents/skills/${name}"
    done
    log "Linked OpenSpec skills from .cursor/skills"
  fi
}

install_graphify() {
  ensure_path
  if ! command -v graphify >/dev/null 2>&1; then
    log "Installing graphifyy via uv ..."
    if ! command -v uv >/dev/null 2>&1; then
      curl -LsSf https://astral.sh/uv/install.sh | sh
      # shellcheck disable=SC1091
      [[ -f "${HOME}/.local/bin/env" ]] && source "${HOME}/.local/bin/env"
    fi
    uv tool install graphifyy
  else
    log "graphify already installed"
  fi

  if [[ -d "${HOME}/gstack" ]]; then
    (cd "${HOME}/gstack" && graphify cursor install 2>/dev/null || true)
  fi
}

install_impeccable() {
  log "Installing impeccable skills ..."
  if [[ -d "${HOME}/gstack/.agents/skills/impeccable" ]]; then
    ln -sfn "${HOME}/gstack/.agents/skills/impeccable" "${HOME}/.agents/skills/impeccable"
    log "Linked impeccable from gstack project install"
  else
  (
    cd "${HOME}/gstack" 2>/dev/null || cd "${ROOT}"
    npx --yes impeccable skills install 2>/dev/null || true
  )
    if [[ -d "${HOME}/gstack/.agents/skills/impeccable" ]]; then
      ln -sfn "${HOME}/gstack/.agents/skills/impeccable" "${HOME}/.agents/skills/impeccable"
    fi
  fi
}

install_context7_mcp() {
  local mcp_file="${HOME}/.cursor/mcp.json"
  mkdir -p "${HOME}/.cursor"

  if [[ -f "${mcp_file}" ]] && grep -q '"context7"' "${mcp_file}" 2>/dev/null; then
    log "Context7 already in ${mcp_file}"
    return 0
  fi

  log "Adding Context7 to ${mcp_file} ..."
  if [[ -f "${mcp_file}" ]]; then
  python3 - <<'PY' "${mcp_file}"
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
cfg.setdefault("mcpServers", {})["context7"] = {
    "command": "npx",
    "args": ["-y", "@upstash/context7-mcp@latest"]
}
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
  else
    cat > "${mcp_file}" <<'EOF'
{
  "mcpServers": {
    "context7": {
      "command": "npx",
      "args": ["-y", "@upstash/context7-mcp@latest"]
    }
  }
}
EOF
  fi
  log "Context7 MCP configured (set CONTEXT7_API_KEY for authenticated access)"
}

install_praxstack_packs() {
  # PraxStack extension packs (2026 expanded list)
  install_pack_select mvanhorn/last30days-skill last30days
  install_pack_select 24601/agent-deep-research deep-research
  install_pack_select nutlope/hallmark hallmark
  install_pack_select vercel-labs/agent-skills web-design-guidelines
  install_pack_select google-labs-code/stitch-skills stitch-generate-design stitch-react-components stitch-code-to-design
  install_pack_all remotion-dev/skills

  # wshobson/agents — selective (not all 181)
  install_pack_select wshobson/agents \
    api-design-principles \
    architecture-patterns \
    architecture-decision-records \
    code-review-excellence \
    context-driven-development \
    microservices-patterns \
    auth-implementation-patterns \
    accessibility-compliance \
    before-you-build \
    hads \
    cqrs-implementation \
    bash-defensive-patterns \
    event-store-design \
    projection-patterns

  # nvidia/skills — selective (GPU/AI infra on demand)
  install_pack_select nvidia/skills \
    nvidia-skill-finder \
    cudaq-guide \
    jetson-quick-start \
    deepstream-dev \
    nemo-rl-docs \
    physicsnemo-discover \
    dynamo-troubleshoot \
    rag-blueprint
}

install_pack_all() {
  install_pack "$1" --skill '*'
}

main() {
  ensure_path
  log "PraxStack full install"
  log "Manifest: ${ROOT}/.agents/super-pro-packs.json"
  log "Docs: ${ROOT}/docs/super-pro-stack.md"

  if [[ "$SKIP_SUPER_PRO" == false ]]; then
    install_super_pro
  fi

  install_praxstack_packs
  bash "${ROOT}/scripts/install-praxstack-personas.sh"
  install_openspec_global
  install_graphify
  install_impeccable
  install_context7_mcp

  if [[ "$WITH_GSTACK" == true ]]; then
    bash "${ROOT}/scripts/install-gstack-skills.sh" --skip-setup 2>/dev/null || \
      bash "${ROOT}/scripts/install-gstack-skills.sh"
  fi

  log "Done. Verify: bash scripts/verify-super-pro-skills.sh"
  log "Global lock: ${HOME}/.agents/.skill-lock.json"
}

main "$@"
