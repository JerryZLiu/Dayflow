#!/usr/bin/env bash
# Install gstack skills for Cursor Cloud Agents.
#
# gstack's ./setup --host cursor writes to ~/.cursor/skills (gstack-* dirs).
# Cloud Agents and the skills CLI also discover skills from ~/.agents/skills,
# so this script links each gstack skill there using the short name from
# SKILL.md frontmatter (e.g. plan-ceo-review → /plan-ceo-review).
#
# Usage:
#   bash scripts/install-gstack-skills.sh [--skip-setup]
#
# Options:
#   --skip-setup   Only refresh ~/.agents/skills symlinks (skip clone/build)

set -euo pipefail

GSTACK_DIR="${GSTACK_DIR:-${HOME}/gstack}"
GSTACK_REPO="${GSTACK_REPO:-https://github.com/garrytan/gstack.git}"
CURSOR_SKILLS="${HOME}/.cursor/skills"
AGENTS_SKILLS="${HOME}/.agents/skills"
SKIP_SETUP=false

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-setup) SKIP_SETUP=true ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

log() { echo "[install-gstack] $*"; }

ensure_path() {
  export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:${HOME}/.bun/bin:${PATH}"
}

ensure_gstack_repo() {
  if [[ -d "${GSTACK_DIR}/.git" ]]; then
    log "gstack repo present at ${GSTACK_DIR}"
    return 0
  fi

  log "Cloning gstack from ${GSTACK_REPO} ..."
  git clone --single-branch --depth 1 "${GSTACK_REPO}" "${GSTACK_DIR}"
}

run_gstack_setup() {
  ensure_path

  if ! command -v bun >/dev/null 2>&1; then
    log "Installing bun (required by gstack setup) ..."
    curl -fsSL https://bun.sh/install | bash
    ensure_path
  fi

  log "Running gstack setup --host cursor ..."
  (cd "${GSTACK_DIR}" && ./setup --host cursor)
}

skill_name_from_frontmatter() {
  local skill_md="$1"
  local name=""
  name="$(awk '
    /^---$/ { in_fm = !in_fm; next }
    in_fm && /^name:/ {
      sub(/^name:[[:space:]]*/, "")
      print
      exit
    }
  ' "${skill_md}" 2>/dev/null || true)"
  printf '%s' "${name}"
}

link_gstack_skills_to_agents() {
  mkdir -p "${AGENTS_SKILLS}"

  if [[ ! -d "${CURSOR_SKILLS}" ]]; then
    log "ERROR: ${CURSOR_SKILLS} not found. Run gstack setup first." >&2
    return 1
  fi

  local linked=0
  local skipped=0

  # Runtime root (bin/, browse/dist/, etc.)
  if [[ -d "${CURSOR_SKILLS}/gstack" ]]; then
    ln -sfn "${CURSOR_SKILLS}/gstack" "${AGENTS_SKILLS}/gstack"
    linked=$((linked + 1))
  fi

  for skill_dir in "${CURSOR_SKILLS}"/gstack-*/; do
    [[ -d "${skill_dir}" ]] || continue
    [[ -f "${skill_dir}/SKILL.md" ]] || continue

    local short_name
    short_name="$(skill_name_from_frontmatter "${skill_dir}/SKILL.md")"
    if [[ -z "${short_name}" ]]; then
      log "warning: no name: in ${skill_dir}/SKILL.md — skipping"
      skipped=$((skipped + 1))
      continue
    fi

    local target="${AGENTS_SKILLS}/${short_name}"
    if [[ -e "${target}" && ! -L "${target}" ]]; then
      log "warning: ${target} exists and is not a symlink — leaving in place"
      skipped=$((skipped + 1))
      continue
    fi

    ln -sfn "${skill_dir}" "${target}"
    linked=$((linked + 1))
  done

  log "Linked ${linked} gstack skill(s) into ${AGENTS_SKILLS} (${skipped} skipped)"
}

verify_key_skills() {
  local missing=0
  for skill in plan-ceo-review office-hours review qa ship; do
    if [[ -f "${AGENTS_SKILLS}/${skill}/SKILL.md" ]]; then
      log "verified: ${skill}"
    else
      log "ERROR: missing ${AGENTS_SKILLS}/${skill}/SKILL.md" >&2
      missing=$((missing + 1))
    fi
  done
  return "${missing}"
}

main() {
  ensure_path

  if [[ "${SKIP_SETUP}" == false ]]; then
    ensure_gstack_repo
    run_gstack_setup
  fi

  link_gstack_skills_to_agents
  verify_key_skills
  log "Done. Use slash commands like /plan-ceo-review in Cursor."
}

main "$@"
