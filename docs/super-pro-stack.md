# PraxStack — Super-Pro AI Developer Stack

**Owner:** Prax  
**Repository:** [praxstack/JerryZLiu-Dayflow](https://github.com/praxstack/JerryZLiu-Dayflow)  
**Last updated:** 2026-08-29

PraxStack is the expanded 2026 agent skill ecosystem for Dayflow Cloud Agents and local Cursor development. Skills install **globally** to `~/.agents/skills` (Cloud Agent discovery path — **not** only `~/.cursor/skills`).

---

## Quick start

```bash
# Full PraxStack (super-pro + extensions: OpenSpec, Graphify, Stitch, etc.)
bash scripts/install-praxstack-skills.sh --with-tools

# Base super-pro only
bash scripts/install-super-pro-skills.sh

# gstack only (clone + setup + ~/.agents/skills symlinks)
bash scripts/install-gstack-skills.sh

# Verify key skills, slash commands, and tools
bash scripts/verify-super-pro-skills.sh
```

**Sync / lock file:** `~/.agents/.skill-lock.json` (skills CLI v3). Manifest: `.agents/super-pro-packs.json`. Re-run install on fresh VMs.

**Cloud Agent VM:** Skills are user-level. Run `install-praxstack-skills.sh` once per agent user after boot (or bake into environment snapshot).

---

## PraxStack architecture (2026)

PraxStack layers **discover → spec → plan → implement → review → security → QA → ship → learn**, with MCP tools (Context7, Serena) and CLIs (OpenSpec, Graphify, specify) at the edges.

| Layer | Purpose | PraxStack tools/skills |
|-------|---------|------------------------|
| 1. **Discover** | Find skills, trends, docs | `find-skills`, `last30days`, `deep-research`, Context7 MCP, `nvidia-skill-finder` |
| 2. **Spec** | Formalize before coding | OpenSpec (`/opsx-propose`), `specify` (Spec Kit), gstack `spec`, `ce-plan` |
| 3. **Interrogate** | Clarify scope and risks | superpowers `brainstorming`, `karpathy-guidelines`, gstack `plan-ceo-review` |
| 4. **Plan** | Structured plans | `executing-plans`, gstack `autoplan`, wshobson `architecture-patterns` |
| 5. **Implement** | Disciplined coding | superpowers TDD, mattpocock, `improve`, Stitch, Remotion, `impeccable` |
| 6. **Review** | Quality gates | `code-review`, `ce-code-review`, gstack `review`, `web-design-guidelines` |
| 7. **Security** | Hardening | trailofbits, jwynia scans, wshobson `auth-implementation-patterns` |
| 8. **Browser QA** | Visual/E2E | `agent-browser`, gstack `qa`/`browse`, `hallmark` |
| 9. **Ship** | PR/deploy | gstack `ship`, `ce-commit-push-pr`, OpenSpec archive |
| 10. **Learn** | Compound knowledge | `ce-compound`, gstack `learn`, `continual-learning` |

### Discovery paths

| Path | Used by | Notes |
|------|---------|-------|
| `~/.agents/skills/` | **Cloud Agents** | Primary — install scripts symlink here |
| `~/.cursor/skills/` | Cursor Desktop, gstack setup | gstack writes `gstack-*` dirs here |
| `.cursor/skills/` (repo) | OpenSpec project skills | Linked to `~/.agents/skills` by install script |

---

## 10-Layer diagram

```
┌─────────────┐     ┌─────────────┐     ┌──────────────┐
│  Discover   │────▶│    Spec     │────▶│ Interrogate  │
│ find-skills │     │ openspec    │     │ brainstorm   │
│ last30days  │     │ specify     │     │ plan-ceo     │
└─────────────┘     └─────────────┘     └──────────────┘
       │                                        │
       ▼                                        ▼
┌─────────────┐     ┌─────────────┐     ┌──────────────┐
│    Plan     │────▶│ Implement   │────▶│   Review     │
│ ce-plan     │     │ improve/TDD │     │ code-review  │
└─────────────┘     └─────────────┘     └──────────────┘
       │                   │                    │
       ▼                   ▼                    ▼
┌─────────────┐     ┌─────────────┐     ┌──────────────┐
│  Security   │     │ Browser QA  │────▶│    Ship      │────▶ Learn
│ trailofbits │     │agent-browser│     │ gstack ship  │      ce-compound
└─────────────┘     └─────────────┘     └──────────────┘
```

---

## Core systems

| # | System | Role | Install |
|---|--------|------|---------|
| 1 | **Skills CLI** | Universal installer | `npx skills@latest` |
| 2 | **find-skills** | Meta-discovery | `~/.agents/skills/find-skills` |
| 3 | **gstack** | Full dev lifecycle | `~/gstack` + symlinks |
| 4 | **superpowers** | Workflow discipline | `~/.agents/skills` |
| 5 | **Compound Engineering** | Product loop | `~/.agents/skills/ce-*` |
| 6 | **trailofbits/skills** | Security analysis | `~/.agents/skills` |
| 7 | **agent-browser** | Headless browser | npm global |
| 8 | **Spec Kit (specify-cli)** | Spec-driven CLI | `uv tool install specify-cli` |
| 9 | **OpenSpec** | Change proposals | `npm i -g @fission-ai/openspec` |
| 10 | **Context7** | Live library docs MCP | `~/.cursor/mcp.json` |
| 11 | **Graphify** | Code knowledge graph | `uv tool install graphifyy` |
| 12 | **pstack** | Poteto-mode (Desktop) | `/add-plugin pstack` |
| 13 | **skills-and-personas** | Prax personal workflow layer | `bash scripts/install-praxstack-personas.sh` |

---

## Prax personal workflow layer (skills-and-personas)

**Source:** [praxstack/skills-and-personas](https://github.com/praxstack/skills-and-personas)  
**Install:** `bash scripts/install-praxstack-personas.sh` (also runs as part of `install-praxstack-skills.sh`)

This is Prax's curated portfolio of production skills distilled from personas, team roles, and knowledge packs. It sits **on top of** the super-pro base stack.

### What gets installed

| Layer | Path | Purpose |
|-------|------|---------|
| **Canonical skills** (41) | `~/.agents/skills/<name>/` | Symlinked from `new-skills/` — linted, council-reviewed |
| **Legacy + public skills** (87 total via npx) | `~/.agents/skills/` | Includes `teach-pro-max`, `superimprove`, `coding-agent-leadership-principles`, brain-ingest suite, etc. |
| **Personas** (reference) | `~/.agents/personas/` | Raw persona packs — not auto-discovered; use when you need source prompts |
| **Manifest stamp** | `~/.agents/.skills-and-personas.json` | Commit SHA + install timestamp |

**Cached clone:** `~/.agents/praxstack/skills-and-personas`

### Goals

There is **no separate goals/ directory** or Cursor CreateGoal integration in this repo. "Goals" are embedded in skill descriptions and persona prompts (e.g. `product-manager` for roadmap goals, `apex-autonomous-mode` for execution contracts, `chronicle` for journaling goals). Invoke the relevant skill for goal-oriented work.

### Personas (reference layer)

Personas are preserved source material; skills in `new-skills/` are the production runtime form.

| Persona | Skill equivalent | Purpose |
|---------|------------------|---------|
| Ren Nakamura | `techtutor` | Intuition-first technical mentor (DSA, system design, AI/ML) |
| Gabriel Petersson | `gabriel-petersson-topdown-mentor` | Top-down recursive gap-filling learning |
| Lecture Alchemist | `lecture-alchemist` | Zoom transcript → retention-optimized study materials |
| Professor Alex | `professor-alex-interview` | FAANG/HFT interview prep with guided discovery |
| Chronicle | `chronicle` | Personal journal intelligence with pattern analysis |
| Baron von Markup | `baron-von-markup` | Markdown formatting architect |
| Constellation Team | `constellation-team` | Six-role cross-functional team workflow |
| Teach Pro Max | `teach-pro-max` | Evidence-oriented adaptive teaching system |
| prax-lannister | — | Memory/context prompt for Prax-specific context |

**md-personas/** single-file prompts: `KINGMODE.md`, `SUPER-MODE.md`, `ULTRATHINK-FRONTEND.md`, `CONSTELLATION-TEAM.md`, `FRONTEND-DESIGN.md`, `FRONTEND-PE.md`, `BACKEND-PE.md`

### Key slash commands (skills-and-personas)

| Command | Skill | Purpose |
|---------|-------|---------|
| `/kingmode` | kingmode | Principal-engineer depth routing (backend/frontend/security) |
| `/apex-autonomous-mode` or `/apex` | apex-autonomous-mode | Rigorous autonomous execution with keep-or-revert |
| `/techtutor` | techtutor | Intuition-first explanations with 6-layer framework |
| `/chronicle` | chronicle | Personal journal intelligence |
| `/teach-pro-max` | teach-pro-max | Adaptive teaching with evidence tracking |
| `/constellation-team` | constellation-team | Cross-functional team roles (PM, PE, QA, DevOps, etc.) |
| `/blueprint-creator` | blueprint-creator | Expand SPEC.md into implementation bible |
| `/superimprove` | superimprove | Bounded audit-fix-review-verify loop |
| `/backend-pe` | backend-pe | Backend PE orchestrator (routes to language variants) |
| `/product-manager` | product-manager | PRDs, roadmap, prioritization |
| `/professor-alex-interview` | professor-alex-interview | FAANG/HFT mock interviews |
| `/lecture-alchemist` | lecture-alchemist | Transcript → study materials |
| `/mental-health-screening-companion` | mental-health-screening-companion | Scoped self-reflection (see SAFETY.md) |

Language-specific backend: `/backend-pe-python`, `/backend-pe-typescript`, `/backend-pe-java`, `/backend-pe-cpp`, `/backend-pe-nodejs`, `/backend-pe-javascript`, `/backend-pe-python-ml`

### Install flags

```bash
bash scripts/install-praxstack-personas.sh              # Full install
bash scripts/install-praxstack-personas.sh --skip-npx   # Only symlink new-skills/
bash scripts/install-praxstack-personas.sh --skip-personas  # Skills only
bash scripts/install-praxstack-personas.sh --refresh    # git pull cached clone
```

---

## PraxStack extension packs (2026)

| Pack | Mode | Notes |
|------|------|-------|
| `mvanhorn/last30days-skill` | selective | `last30days` — recent trends research |
| `24601/agent-deep-research` | selective | `deep-research` |
| `nutlope/hallmark` | selective | `hallmark` — landing page QA |
| `vercel-labs/agent-skills` | selective | `web-design-guidelines` (rules from web-interface-guidelines repo) |
| `google-labs-code/stitch-skills` | selective | Stitch design→code (3 skills) |
| `remotion-dev/skills` | full | Video/remotion workflows |
| `wshobson/agents` | **selective (14)** | Do **not** install all 181 |
| `nvidia/skills` | **selective (8)** | GPU/AI infra on demand |
| **OpenSpec** | CLI + repo | `/opsx-propose`, `.cursor/skills/openspec-*` |
| **Graphify** | uv tool | `/graphify` — knowledge graph |
| **Impeccable** | npx | `/impeccable` — design context |
| **Context7** | MCP | `@upstash/context7-mcp` in mcp.json |
| **Serena** | MCP (manual) | `uvx --from git+https://github.com/oraios/serena serena-mcp-server` |

### wshobson/agents — selective (14 installed)

`api-design-principles`, `architecture-patterns`, `architecture-decision-records`, `code-review-excellence`, `context-driven-development`, `microservices-patterns`, `auth-implementation-patterns`, `accessibility-compliance`, `before-you-build`, `hads`, `cqrs-implementation`, `bash-defensive-patterns`, `event-store-design`, `projection-patterns`

### nvidia/skills — selective (8 installed)

`nvidia-skill-finder`, `cudaq-guide`, `jetson-quick-start`, `deepstream-dev`, `nemo-rl-docs`, `physicsnemo-discover`, `dynamo-troubleshoot`, `rag-blueprint`

---

## Super-pro base packs

| Pack | Mode | Skills | Notes |
|------|------|--------|-------|
| `vercel-labs/skills` | selective | `find-skills` | Install first |
| `trailofbits/skills` | full | 80 | Security |
| `vercel-labs/agent-browser` | selective | `agent-browser` | + npm global CLI |
| `anthropics/skills` | full | 17 | Subset on demand |
| `github/awesome-copilot` | full | 415 | On demand |
| `microsoft/skills` | selective | 8 | Avoid context rot |
| `EveryInc/compound-engineering-plugin` | full | 34 | Product loop |
| `shadcn/improve` | selective | `improve` | UI polish |
| `mattpocock/skills` | full | 37 | TypeScript/React |
| `obra/superpowers` | full | 13 | Workflow discipline |
| `addyosmani/agent-skills` | full | 25 | General patterns |
| `vercel-labs/agent-skills` | full | 9+ | Vercel/Next.js |
| `supabase/agent-skills` | full | 2 | Optional |
| `cloudflare/skills` | full | 13 | Optional |
| `aws/agent-toolkit-for-aws` | selective | 6 | Optional |
| `forrestchang/andrej-karpathy-skills` | full | 1 | `karpathy-guidelines` |
| `brainqub3/red-green-refactor` | full | 6 | TDD variants |
| `jwynia/agent-skills` | selective | 3 | Security scans |
| `pproenca/dot-skills` | selective | `tdd` | Methodology |
| **gstack** | script | 54 | `./setup --host cursor` |
| **pstack** | Desktop | 7 | `/add-plugin pstack` |
| **specify-cli** | uv tool | — | Spec Kit |

### microsoft/skills — selective (8 installed, 5 skipped)

**Installed:** `continual-learning`, `frontend-design-review`, `github-issue-creator`, `mcp-builder`, `skill-creator`, `copilot-sdk`, `microsoft-docs`, `cloud-solution-architect`

**Skipped:** `applicationinsights-web-ts`, `debugview`, `entra-agent-id`, `kql`, `podcast-generation`

### openai/skills — deprecated

OpenAI's standalone skills repo is deprecated. Use `anthropics/skills` and reference [openai/plugins](https://github.com/openai/plugins) for legacy plugin format only.

---

## Key slash commands

After install, these workflows are available via `/command`:

| Command | Source | Purpose |
|---------|--------|---------|
| `/plan-ceo-review` | gstack | CEO-level plan review |
| `/find-skills` | vercel-labs | Discover skills |
| `/improve` | shadcn | UI polish |
| `/office-hours` | gstack | Design consultation |
| `/review` | gstack | Code review workflow |
| `/qa` | gstack | Browser QA |
| `/ship` | gstack | Commit/PR/deploy |
| `/opsx-propose` | OpenSpec | Propose a change |
| `/impeccable` | impeccable | Design context |
| `/last30days` | last30days | Recent trends research |
| `/deep-research` | agent-deep-research | Deep research |
| `/hallmark` | hallmark | Landing page audit |
| `/web-design-guidelines` | vercel | UI/accessibility audit |

gstack also provides `/spec`, `/autoplan`, `/learn`, `/browse`, and 40+ more (see `~/gstack`).

---

## Desktop-only steps (Cursor IDE)

Cannot be fully activated on Cloud Agent VM:

```
/add-plugin pstack
/add-plugin superpowers
/add-plugin compound-engineering
```

VM has skill *files* in `~/.agents/skills`; Desktop plugins wire IDE UI.

### Serena MCP (manual)

Add to `~/.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "serena": {
      "command": "uvx",
      "args": ["--from", "git+https://github.com/oraios/serena", "serena-mcp-server"]
    }
  }
}
```

### Context7 API key

For authenticated Context7 access, set `CONTEXT7_API_KEY` or add to mcp.json env:

```json
"context7": {
  "command": "npx",
  "args": ["-y", "@upstash/context7-mcp@latest"],
  "env": { "CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}" }
}
```

---

## gstack setup

```bash
bash scripts/install-gstack-skills.sh
```

Clones [garrytan/gstack](https://github.com/garrytan/gstack), runs `./setup --host cursor`, symlinks short names into `~/.agents/skills` (e.g. `plan-ceo-review` from `gstack-plan-ceo-review`).

---

## Runtime dependencies

| Tool | Path |
|------|------|
| Node.js | v22+ |
| Skills CLI | `npx skills@latest` |
| agent-browser | `~/.npm-global/bin/agent-browser` |
| specify-cli | `~/.local/bin/specify` |
| openspec | `~/.npm-global/bin/openspec` |
| graphify | `~/.local/bin/graphify` |
| uv | `~/.local/bin/uv` |

**PATH:**

```bash
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.bun/bin:$PATH"
```

---

## Install script flags

```bash
bash scripts/install-praxstack-skills.sh                    # Full PraxStack
bash scripts/install-praxstack-skills.sh --with-tools       # + agent-browser, specify, openspec, graphify
bash scripts/install-praxstack-skills.sh --skip-super-pro   # Extensions only
bash scripts/install-praxstack-skills.sh --skip-optional    # Skip cloud/vendor optional packs
bash scripts/install-praxstack-skills.sh --no-gstack        # Skip gstack
bash scripts/install-praxstack-personas.sh                  # Prax personal workflow only
bash scripts/install-super-pro-skills.sh                    # Base stack only
bash scripts/install-gstack-skills.sh                       # gstack only
```

---

## Overlap warnings

| Domain | Overlapping skills | Recommendation |
|--------|-------------------|----------------|
| **TDD** | superpowers TDD, `tdd`, `red-green-refactor` | Default: superpowers |
| **Code review** | mattpocock, `ce-code-review`, gstack `review` | mattpocock for TS; trailofbits for security |
| **Planning** | superpowers, `ce-plan`, gstack `autoplan` | superpowers small; ce/gstack features |
| **UI audit** | `improve`, `web-design-guidelines`, `hallmark` | improve polish; web-design-guidelines audit |
| **Spec** | OpenSpec, specify, gstack `spec` | OpenSpec for changes; specify for greenfield |
