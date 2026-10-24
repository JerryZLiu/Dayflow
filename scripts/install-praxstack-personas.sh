#!/usr/bin/env bash
# Install Prax's personal skills-and-personas workflow layer for Cloud Agents.
#
# Sources: https://github.com/praxstack/skills-and-personas
# - new-skills/  → canonical 38 production skills (linted, council-reviewed)
# - skills/      → additional public skills (teach-pro-max, superimprove, etc.)
# - personas/    → raw persona packs (symlinked for reference; distilled into skills)
# - md-personas/ → portable single-file persona prompts
#
# Skills install to ~/.agents/skills (Cloud Agent discovery path).
# Personas install to ~/.agents/personas (reference layer, not auto-discovered).
#
# Usage:
#   bash scripts/install-praxstack-personas.sh [options]
#
# Options:
#   --skip-npx        Skip npx skills CLI install (only symlink new-skills/)
#   --skip-personas   Skip persona directory setup
#   --refresh         Force git pull on cached clone
#   -h, --help        Show help

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_URL="https://github.com/praxstack/skills-and-personas.git"
CACHE_DIR="${HOME}/.agents/praxstack/skills-and-personas"
SKILLS_DEST="${HOME}/.agents/skills"
PERSONAS_DEST="${HOME}/.agents/personas"

SKIP_NPX=false
SKIP_PERSONAS=false
REFRESH=false

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-npx) SKIP_NPX=true ;;
    --skip-personas) SKIP_PERSONAS=true ;;
    --refresh) REFRESH=true ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

log() { echo "[install-personas] $*"; }

ensure_path() {
  export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:${HOME}/.bun/bin:${PATH}"
}

clone_or_update_repo() {
  mkdir -p "${HOME}/.agents/praxstack"
  if [[ -d "${CACHE_DIR}/.git" ]]; then
    if [[ "${REFRESH}" == true ]]; then
      log "Updating cached clone ..."
      git -C "${CACHE_DIR}" pull --ff-only origin main
    else
      log "Using cached clone: ${CACHE_DIR}"
    fi
  else
    log "Cloning ${REPO_URL} ..."
    git clone --depth 1 "${REPO_URL}" "${CACHE_DIR}"
  fi
}

install_new_skills() {
  local src="${CACHE_DIR}/new-skills"
  local installed=0

  if [[ ! -d "${src}" ]]; then
    log "ERROR: ${src} not found" >&2
    return 1
  fi

  mkdir -p "${SKILLS_DEST}"
  log "Installing canonical new-skills/ portfolio into ${SKILLS_DEST} ..."

  for skill_dir in "${src}"/*/; do
    [[ -d "${skill_dir}" ]] || continue
    local name
    name="$(basename "${skill_dir}")"
    [[ "${name}" == _audit ]] && continue
    [[ "${name}" == .* ]] && continue
    [[ -f "${skill_dir}/SKILL.md" ]] || continue

    ln -sfn "${skill_dir%/}" "${SKILLS_DEST}/${name}"
    installed=$((installed + 1))
  done

  log "Linked ${installed} canonical skills from new-skills/"
}

install_via_npx() {
  ensure_path
  log "Installing additional skills via npx skills CLI ..."
  npx --yes skills@latest add praxstack/skills-and-personas --skill '*' -g -a cursor -y
}

install_personas() {
  mkdir -p "${PERSONAS_DEST}"

  for sub in personas md-personas team-personas knowledge-packs; do
    if [[ -d "${CACHE_DIR}/${sub}" ]]; then
      ln -sfn "${CACHE_DIR}/${sub}" "${PERSONAS_DEST}/${sub}"
      log "Linked ${sub}/ → ${PERSONAS_DEST}/${sub}"
    fi
  done

  # Codex/Claude agent configs for constellation team
  if [[ -d "${CACHE_DIR}/.codex/agents" ]]; then
    mkdir -p "${PERSONAS_DEST}/codex-agents"
    ln -sfn "${CACHE_DIR}/.codex/agents" "${PERSONAS_DEST}/codex-agents"
    log "Linked .codex/agents → ${PERSONAS_DEST}/codex-agents"
  fi
}

write_manifest_stamp() {
  local sha
  sha="$(git -C "${CACHE_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
  mkdir -p "${HOME}/.agents"
  cat > "${HOME}/.agents/.skills-and-personas.json" <<EOF
{
  "repo": "praxstack/skills-and-personas",
  "commit": "${sha}",
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "skillsPath": "${SKILLS_DEST}",
  "personasPath": "${PERSONAS_DEST}",
  "cacheDir": "${CACHE_DIR}"
}
EOF
  log "Wrote manifest stamp: ~/.agents/.skills-and-personas.json (commit ${sha})"
}

main() {
  log "Prax personal workflow layer (skills-and-personas)"
  log "Repo: ${REPO_URL}"
  log "Dayflow root: ${ROOT}"

  clone_or_update_repo
  install_new_skills

  if [[ "${SKIP_NPX}" == false ]]; then
    install_via_npx || log "WARN: npx skills install had issues (canonical new-skills/ still linked)"
  fi

  if [[ "${SKIP_PERSONAS}" == false ]]; then
    install_personas
  fi

  write_manifest_stamp

  log "Done. Verify: bash scripts/verify-super-pro-skills.sh"
  log "Key slash commands: /kingmode /apex-autonomous-mode /techtutor /chronicle /teach-pro-max"
}

main "$@"
