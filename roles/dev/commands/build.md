---
name: build
version: 0.12.0
description: Implement a feature or change without a ticket. Loads repo patterns, investigates codebase, plans, then builds — iterating phase-by-phase with checkpoints when the plan defines phases.
argument-hint: "describe what you want to build"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Write
  - Edit
  - Task
  - AskUserQuestion
  - EnterPlanMode
  - ExitPlanMode
  - TodoWrite
---
> **Model floor: opus** — same as /ticket without a tracker. This is guidance, not a pin: the command inherits the session model. If you are a smaller model than the floor, say so in one line at the start and continue.

<objective>
Implement "$ARGUMENTS" following all repo conventions and patterns.
No ticket required — the user's description IS the spec.
Investigate first, plan, get approval, then build with full pattern enforcement.
</objective>

<process>

## 0. Detect Target Repository & Load Patterns

Determine which repository to work in:

1. **Parse $ARGUMENTS** for repo hints (e.g., "in addin-fe", "for api-bff")
2. **Check current working directory** — if CWD is inside `$WORKSPACE_ROOT/{repo-name}/`, use that repo. **IMPORTANT:** `$WORKSPACE_ROOT/` itself is NOT a valid target — it's the workspace root.
3. **If still ambiguous**, list available repos and ask the user:
   ```bash
   ls -d $WORKSPACE_ROOT/*/CLAUDE.md 2>/dev/null
   ```

Once identified, store:
- **REPO_ROOT**: absolute path
- **REPO_NAME**: directory name

**Always load:**
- `{REPO_ROOT}/CLAUDE.md` — conventions, commands, architecture

**Defer other files until Step 1 (Understand the Request).** After understanding what's being built, load only what's relevant:
- Simple change (config, small fix) → CLAUDE.md only
- UI feature → + codebase-patterns.md + testing-patterns.md
- Backend work → + codebase-patterns.md + ARCHITECTURE.md
- Testing work → + testing-patterns.md only
- If `$WORKSPACE_ROOT/.claude/codebase-patterns-shared.md` / `testing-patterns-shared.md` exist, load each first (shared rules); then the repo file.

**If `{REPO_ROOT}/CLAUDE.md` does NOT exist AND no `.claude/*.md` files exist**, warn:
> "This repo ({REPO_NAME}) has no CLAUDE.md or pattern files. I'll use generic defaults, but I won't know its conventions. Consider creating a CLAUDE.md."

**Check for active build sessions:**
```bash
ls {REPO_ROOT}/.claude/builds/*.md 2>/dev/null
```
If one exists for a similar scope, ask: "Resume existing build or start fresh?"

**Greenfield detection (before anything else):** `--from-brief` was passed, OR `{REPO_ROOT}` has no package
manifest (`package.json`, `go.mod`, `pyproject.toml`, `Cargo.toml`, `pubspec.yaml`, `*.xcodeproj`, `Gemfile`,
`pom.xml`) and fewer than 3 commits. Then this is **GREENFIELD MODE**:
- Require `{REPO_ROOT}/.claude/project-brief.md` (written by `/new-project`). Missing → stop: "No brief. Run
  `/new-project` first — on an empty repo there is nothing to investigate, only decisions to make."
- Load the brief instead of patterns. Its **Decisions** table is the investigation; a row still `[ ]` is a
  question to ask now, not a guess.
- Steps 2.1–2.4 below are replaced by "investigate the brief"; Phase 0 of the plan is the scaffold (rules in
  §4b); the first feature is Phase 1+.

## 1. Understand the Request

Parse $ARGUMENTS as a plain-text description of what to build. Extract:
- **What**: the feature, change, or fix being requested
- **Where**: any hints about which part of the codebase (component, page, domain)
- **Constraints**: any specific requirements mentioned

If the description is vague, ask clarifying questions BEFORE investigating.

## 2. Enter Plan Mode & Investigate

Enter plan mode with `EnterPlanMode`, then (**greenfield mode: skip 1–4; the brief's Decisions table and
"Repo layout" section are the findings, and the plan's Phase 0 is the scaffold — see §4b**):

1. **Search for existing implementations** — use CLAUDE.md architecture info to know where to look
   - Look for similar features, components, patterns in the repo
   - Check shared/common directories for reusable components
   - **This is critical** — the #1 mistake is building something that already exists

2. **Check related repos** (only if relevant)
   - API endpoints in `$WORKSPACE_ROOT/.claude/api-reference/*.json` (check the spec file for the relevant feature area first)
   - Reference implementations in sibling repos

3. **Identify files to modify/create**

4. **Identify patterns to follow** from:
   - Similar existing code in the repo (primary source)
   - `codebase-patterns.md` rules (if available)
   - `testing-patterns.md` rules (if available)

## 3. Present Plan for Approval

```markdown
# Plan: [brief title]

## What I'll Build
[1-2 sentence summary]

## Investigation Findings
- Existing code to reuse: [paths]
- Pattern to follow: [which existing feature/component]
- Reusable components found: [list from _common or shared]

## Files to Modify/Create
1. `path/to/file` — [what changes]

## Phase Plan (optional — include when work is non-trivial)
Use the same layer/risk-based phasing as `/clarify` Section 4f. Skip the section entirely for trivial changes (single file edit, config tweak, copy change).

### Phase 0 — Setup ({time})
**Files:** —
### Phase 1 — {Title} ({time})
**Files:** {paths}
**Depends on:** —
### Phase 2 — {Title} ({time})
**Files:** {paths}
**Depends on:** Phase 1
...
### Phase {N} — Verify ({time})

## Questions (if any)
- [Anything unclear — DON'T GUESS, ask]
```

**Wait for user approval before implementing.**

## 4. Implement

After plan approval, exit plan mode. **Create state file** at `{REPO_ROOT}/.claude/builds/{scope-slug}.md`:

```yaml
---
scope: {description from $ARGUMENTS}
repo: {REPO_NAME}
status: implementing
branch: {current branch}
created: YYYY-MM-DDTHH:MM:SSZ
updated: YYYY-MM-DDTHH:MM:SSZ
---

## Plan Summary
{approved plan}

## Implementation Progress
| Phase | Status | Notes |
|-------|--------|-------|
| Plan | DONE | |
| Implementation | IN_PROGRESS | |
| Testing | PENDING | |
| Verification | PENDING | |

## Files Modified
{update as work progresses}

## Current Focus
{next step}

## Obsidian Links
- Repo: [[repos/{REPO_NAME}]]
- Patterns: [[codebase-patterns]], [[testing-patterns]]
- Related tickets: {if any PROJ-XXXX tickets are mentioned in $ARGUMENTS or discovered during investigation, list each as [[PROJ-XXXX]]; otherwise write "None"}
```

Implement following ALL loaded patterns. Update the state file as you go.

### 4b. Greenfield Phase 0 — scaffold from the brief (greenfield mode only)

The brief decides; this phase executes it with the framework's **own generator** and **stable versions**:
1. **Versions first.** Pin the runtime to its LTS line (`.nvmrc` / `.tool-versions` / `go.mod` toolchain /
   `pyproject` requires-python) and check each framework's stable channel before installing
   (`npm view <pkg> dist-tags` → use the `lts`/`latest` tag the project's docs call stable; never `next`,
   `canary`, `beta`, `rc`). If the brief names a line, use it; if the channel moved since the brief, say so
   and ask before deviating.
2. **Scaffold with the generator the brief names** (`npm create vite@<stable>`, `npx create-next-app@<stable>`,
   `npx create-expo-app`, `cargo new`, `go mod init` + a known layout, …). Never hand-roll a project tree
   when a maintained generator exists; add only what the brief's "Repo layout" adds on top.
3. **Write the conventions from the decisions, not from code:** fill `CLAUDE.md` (replace every
   `{placeholder}` of the seeded skeleton with the brief's Summary, Architecture, Stack and Repo layout);
   write `.claude/repo-profiles/<repo>.yaml` basics (`name`, `type`, `base_branch`, `ci_command`,
   `lint_command`, `test_command`, `dev_server_url`); seed `codebase-patterns.md` with one entry per
   architecture decision and `testing-patterns.md` with the brief's Testing strategy — each marked
   `_Source: decision:<YYYY-MM-DD>` (the `/learn` recurrence gate accepts decision-sourced entries as
   already-confirmed).
4. **Prove it runs:** install, lint, test, build, start the dev server once; record the commands you used in
   the repo profile. Then commit `chore: scaffold <name> from project-brief` — one commit, before any feature.
5. Hand the scaffold's state file to `/bootstrap` (it configures the rest from what now exists) and continue
   with Phase 1.

### 4a. Phase-aware execution (when the plan defined phases)

**If the approved plan from Step 3 includes a Phase Plan**, iterate phase-by-phase:

For each phase from 1 to N:
1. Update `## Current Focus` in the state file to `Phase {N} — {Title}`.
2. Mark the phase row in `## Implementation Progress` as `IN_PROGRESS`.
3. Use `TodoWrite` for the phase's `Files`.
4. Implement only the files listed for this phase. Touching unlisted files = pause and surface.
5. **Scoped checks** — `npx eslint {phase files}` + `npx tsc --noEmit` if types changed; relevant tests if added. Skip the full `yarn ci` until the final Verify phase.
6. Mark the phase row `DONE`. Update Files Modified.
7. **Checkpoint with the user:**
   > "Phase {N} ({Title}) complete. {1-line summary}. Continue to Phase {N+1} ({next title}), or refine first?"

   Wait for `continue` before starting Phase {N+1}.

The final phase is Verify — at that point fall through to Step 5 below.

### 4b. Non-phased fallback

If the plan has no Phase Plan section, use `TodoWrite` to track each piece of work and implement linearly.

Key rules either way:
- Follow codebase-patterns.md strictly (if loaded)
- Reuse existing components — never duplicate
- Follow the same structure as similar existing code
- Don't guess UI decisions — ask
- **Comment hygiene (write it clean as you go):** default to NO comment; add one ONLY for a non-obvious WHY a maintainer can't infer. NEVER put ticket numbers (`PROJ-XXXX`), section/spec refs (`§16`, `NEW-2`), AC refs (`AC3`), bug-letters (`Bug C`), or before→after history in a comment — that lives in git + the PR ([[feedback_no_bug_letter_comments]]). Enforced by the Comment Hygiene Gate in §5 below and `/pr-creation`.

## 5. Verify

Run quality checks using commands from CLAUDE.md:
- Linting (e.g., `yarn lint`, `npx eslint`)
- Type checking (e.g., `yarn type-check`, `npx tsc --noEmit`)
- Tests for modified/created files (use /test to generate missing tests)
- Full CI command if available
- **Comment Hygiene Gate (BLOCKING)** — linters skip comment style; scan comments ADDED by this change for ticket #, `§`/`NEW-n`/`ACn` refs, bug-letters, history narration, and reasoning-narration noise. Canonical gate + grep: `/verify` §3.4. Any hit → strip it and re-run before presenting.

Fix any issues found. Update state file: Verification → DONE.

## 6. Present Results

Show the user:
1. **What was built** — brief summary
2. **Files changed** — list with descriptions
3. **How to test** — steps to verify the change works
4. **Tests added** — what's covered

**DO NOT** create commits unless explicitly asked.

</process>

<guidelines>
- **Patterns are mandatory, not suggestions.** If codebase-patterns.md says "use CSS variables", use CSS variables. If it says "check _common first", check _common first. No exceptions.
- **Investigate before building.** The most common mistake is building from scratch when a reusable component or pattern already exists in the codebase.
- **Ask, don't guess.** If the user's description doesn't specify something (layout, behavior, edge case), ask.
- **Stay scoped.** Build exactly what was asked. Don't refactor surrounding code, add bonus features, or "improve" things.
- **Test what you build.** Follow testing-patterns.md if available. At minimum, run existing tests to ensure nothing broke.
</guidelines>

## Related Commands
- Verify: /verify (check implementation)
- Deliver: /pr-creation (generate PR)
- Testing: /test | /e2e
- If interrupted: /resume-ticket
- Patterns: codebase-patterns.md | testing-patterns.md
