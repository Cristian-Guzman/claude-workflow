---
name: ticket
version: 0.3.1
model: "opus[1m]"
description: Start implementing a Jira ticket. Reads the persisted clarify blueprint (if present), seeds phase-based progress, and iterates phases with checkpoints so each chunk stays small enough for Claude Code to ship reliably.
argument-hint: "PROJ-XXXX [paste acceptance criteria]"
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

<objective>
Investigate and plan implementation for ticket $ARGUMENTS.
Detect the target repository, load its conventions, and follow the ticket workflow end-to-end.
Create and maintain a ticket state file for context persistence.
</objective>

<process>

## 0. Detect Target Repository & Load Config

Determine which repository this ticket targets:

1. **Parse $ARGUMENTS** for repo hints (e.g., "in ios-app", "for api-bff", "addin-fe")
2. **Check current working directory** — if CWD is inside a sub-repo of `$WORKSPACE_ROOT/{repo-name}/`, use that repo. **IMPORTANT:** `$WORKSPACE_ROOT/` itself is NOT a valid target — it's the workspace root containing all repos. Only match if CWD is at least one level deeper (e.g., `$WORKSPACE_ROOT/api-bff/...`).
3. **If still ambiguous**, list available repos and **always ask the user** using `AskUserQuestion`:
   ```bash
   ls -d $WORKSPACE_ROOT/*/CLAUDE.md 2>/dev/null
   ```

Once identified, store context:
- **REPO_ROOT**: absolute path (e.g., `$WORKSPACE_ROOT/ios-app`)
- **REPO_NAME**: directory name (e.g., `ios-app`)

**Always load (minimal baseline):**
- `{REPO_ROOT}/CLAUDE.md` — conventions, commands, architecture (ALWAYS needed)

**If `{REPO_ROOT}/CLAUDE.md` does NOT exist**, warn the user immediately:
> "This repo ({REPO_NAME}) doesn't have a CLAUDE.md. Consider creating one or running `/bootstrap`."

**DO NOT load pattern files, agents, or architecture docs yet.** Wait until Step 1.1 (Classify Ticket Type) to decide what else to load. This saves tokens on simple tickets.

**Token optimization:** If the repo has a `codebase-patterns-index.md`, use it to load only relevant sections of `codebase-patterns.md` instead of the full file. A deps ticket reading core rules only (~250 lines) vs the full file (~3,000+ lines) saves ~10K tokens.

**Ensure state directories exist:**
```bash
mkdir -p {REPO_ROOT}/.claude/tickets
```

## 0.7 Load Persisted Clarify Blueprint (if present)

After determining `REPO_ROOT` and the ticket ID, look for `{REPO_ROOT}/.claude/tickets/PROJ-XXXX-clarify.md`. If present, read it and extract:

- `phases` (from frontmatter): integer count OR `skipped`
- `## Phase Plan` block (parse `### Phase N — {Title} ({time})` headers and their `**Goal:**`, `**ACs:**`, `**Files:**`, `**Depends on:**` fields)
- `## File Placement`, `## Patterns to Follow`, `## API Contract`, `## Dependencies`, `## Conclusions` tables
- `## Remaining Questions`

Store as **CLARIFY_BLUEPRINT** and **PHASE_PLAN** in memory.

**Behavior when blueprint exists:**
- **Trust it.** Do NOT re-run codebase-investigator or the 6-axis investigation in Step 2 — clarify already did the work. Skip Step 2's "Search for existing implementations" and jump straight to confirming the plan with the user.
- **If `phases: skipped`**, run the existing single-pass flow (no phase iteration).
- **If `phases: N`**, seed the state file's `## Implementation Progress` table with one row per phase (see Step 1 below) and iterate phases in Step 5.
- **If Remaining Questions includes blocking items that look unanswered**, stop and ask the user whether to proceed anyway or wait for PM input.

**Behavior when blueprint is absent:**
- Warn once: *"No `PROJ-XXXX-clarify.md` found. Running with single-pass flow. Consider `/clarify PROJ-XXXX` first to get a Phase Plan."* Then continue with the existing flow unchanged.

This step replaces re-investigation — the blueprint is the single source of truth.

## 1. Parse Input & Create Ticket State File

Parse ticket number (PROJ-XXXX) from $ARGUMENTS.

**Fetch from Jira (try in order):**
1. **MCP**: Use the Atlassian MCP tools (`mcp__atlassian__getJiraIssue`) if available
2. **CLI fallback**: If MCP is unavailable, use the Jira CLI:
   ```bash
   jira issue view PROJ-XXXX --plain
   ```
3. **Manual fallback**: If both fail, ask the user to paste the acceptance criteria

Extract: summary, description, acceptance criteria, story points, and linked tickets.

**Obsidian wiki links:** When creating or updating the state file, wrap all ticket IDs (the current ticket and any related/linked/blocking tickets) in `[[PROJ-XXXX]]` wiki link syntax so they are navigable in Obsidian. Populate the `## Obsidian Links` section at the bottom with the actual repo name and any linked tickets discovered from Jira.

Create ticket state file at `{REPO_ROOT}/.claude/tickets/PROJ-XXXX.md`:

```markdown
---
ticket: PROJ-XXXX
repo: {REPO_NAME}
status: planning
branch: (to be determined)
created: YYYY-MM-DDTHH:MM:SSZ
updated: YYYY-MM-DDTHH:MM:SSZ
---

## Acceptance Criteria
- [ ] AC1: [from Jira ticket or user input]
- [ ] AC2: [from Jira ticket or user input]

## Plan Summary
(Pending investigation)

## Implementation Progress

**When a PHASE_PLAN was loaded from `PROJ-XXXX-clarify.md`** (Step 0.7, `phases: N`), seed this table with one row per phase from the blueprint:

| Phase | Status | Notes |
|-------|--------|-------|
| 0 — Setup | PENDING | branch + state file |
| 1 — {Title from clarify} | PENDING | ACs: {ids}; depends on: — |
| 2 — {Title from clarify} | PENDING | ACs: {ids}; depends on: Phase 1 |
| ... | PENDING | ... |
| {N} — Verify | PENDING | yarn ci, lint, smoke |

**Otherwise (no phase plan, or `phases: skipped`)**, use the default 5-row table:

| Phase | Status | Notes |
|-------|--------|-------|
| Plan | IN_PROGRESS | Investigating codebase |
| Implementation | PENDING | |
| Testing | PENDING | |
| Verification | PENDING | |
| Delivery | PENDING | |

## Files Modified
(none yet)

## Decisions Made
(none yet)

## Current Focus
Starting investigation for ticket implementation.

## Blockers / Questions Resolved
(none yet)

## Event Log
(append entries as work progresses — these feed /learn)

## Retrospective
(filled at delivery)
- **What went well:**
- **What went wrong:**
- **Surprises about the codebase:**

## Obsidian Links
- Repo: [[repos/{REPO_NAME}]]
- Patterns: [[codebase-patterns]], [[testing-patterns]]
- Related: [[PROJ-YYYY]] (linked tickets from Jira, if any)
```

## 1.1 Classify Ticket — Tier & Context Profile

Classify the ticket into a **tier** BEFORE any investigation or Plan Mode. This determines how much context to load and how deep the verification will be. The classification is saved in the state file so `/verify` can match its depth.

> **Canonical source:** the tier signals and per-tier load profile live in `$WORKSPACE_ROOT/.claude/routing.md` (shared with `/do` and `/clarify` so they never drift). The matrix below mirrors it — if you change loading rules, change `routing.md` first.

### Tier Classification

| Tier | Criteria | Plan Mode | Verification Depth |
|------|----------|-----------|-------------------|
| **Trivial** | Deps update, config change, copy/text change, single-file fix with clear cause | Skip entirely | Tests + CI → DONE (HIGH) |
| **Bugfix** | Clear repro, known file(s), no new architecture. FILE MAP has 1-3 MODIFY, 0 CREATE. | Lightweight — affected files + direct deps only | Standard + contract smoke test if API involved |
| **Standard** | New component, hook, page section. Extends existing patterns. FILE MAP has 3-6 files. | Normal — targeted investigation of similar features | Full unit + contract + E2E if specified |
| **Complex** | New domain, cross-cutting, multi-repo, no existing reference. 7+ files or 8+ story points. | Full — all 6 categories | Full + never HIGH confidence without E2E |

### How to Classify

Use these signals from the ticket:

**Keywords:**
- "bump", "update", "upgrade", "dependabot", "chore", "config", "env" → **Trivial**
- "fix", "bug", "broken", "crash", "not working" → **Bugfix**
- "build", "add", "create", "implement" with ≤6 files → **Standard**
- "build", "create", "implement" with 7+ files, or "new page", "new domain" → **Complex**

**FILE MAP** (if present):
- All MODIFY, no CREATE → likely Bugfix
- 1-2 CREATE + some MODIFY → Standard
- 5+ CREATE → Complex

**Story Points:** 1-2 → Trivial/Bugfix. 3-5 → Standard. 8+ → Complex.

**ACs:** 1-2 → Trivial/Bugfix. 3-5 → Standard. 6+ → Complex.

**Dependencies:** No blockers → simpler. Multiple BLOCKS entries → Complex.

**If in doubt, go one tier UP** — better to over-investigate than under-investigate.
The user can override: "this is actually complex" or "treat this as trivial."

### Context Loading per Tier

```
Trivial:
  - CLAUDE.md only
  - testing-patterns.md (for running tests correctly)
  - Skip: codebase-patterns, API reference, Confluence, agents

Bugfix:
  - CLAUDE.md
  - codebase-patterns.md (core rules only via index, ~250 lines)
  - testing-patterns.md
  - Specific API reference JSON ONLY if the bug involves an API endpoint
  - Skip: full investigation, Confluence, agents

Standard:
  - CLAUDE.md
  - codebase-patterns.md (core rules + relevant sections via index)
  - testing-patterns.md
  - business-context.md (grep for relevant domain section — e.g., billing, documents, notifications, etc.)
  - Relevant API reference JSONs (based on endpoints in the ticket)
  - ticket-checklist.md
  - Investigate similar existing features for patterns
  - Load agents (verifier, ux-reviewer if available)

Complex:
  - Everything: codebase-patterns.md (full), testing-patterns.md, ticket-checklist.md
  - business-context.md (read fully — domain knowledge is critical for complex tickets)
  - All relevant API reference JSONs
  - Full 6-category investigation
  - Confluence for business context
  - Check web-app for legacy business logic if applicable
  - Load all agents
```

**For tickets in a domain that has both v1 and v2 API surfaces** (any tier), prioritize the v2 reference JSON (e.g., `{domain}-v2-api.json` over `{domain}-api.json`):
```bash
grep -i "{keyword}" $WORKSPACE_ROOT/.claude/api-reference/{domain}-v2-api.json 2>/dev/null | head -10
```

### Output the Classification

At the start of every /ticket run, output:

```markdown
## Ticket Classification

**Ticket:** PROJ-XXXX
**Tier:** {Trivial | Bugfix | Standard | Complex}
**Reason:** {e.g., "FILE MAP has 2 MODIFY files, 0 CREATE. Keywords: 'fix'. Story points: 2."}
**Context loaded:** {list of files loaded}
**Plan Mode:** {Skip | Lightweight | Normal | Full}
**Verification depth:** {what /verify will check — references the tier}
```

### Save to State File

Add `## Classification` section to the ticket state file:
```markdown
## Classification
- Tier: {Trivial | Bugfix | Standard | Complex}
- Context loaded: {list of files loaded}
- Reason: {why this tier}
- Verification depth: {what /verify should check}
```

This is read by `/verify` to determine how deep to check and what confidence level to assign.

### Tier Workflow Shortcuts

**Trivial:** Skip Plan Mode entirely. Read the relevant file(s), make the change, run tests, done.
> "This looks like a trivial ticket (deps/config/copy change). Skipping investigation — will make the change, run CI, and generate PR deliverables."

**Bugfix:** Lightweight Plan Mode — investigate only affected files and direct dependencies.
> "This looks like a bugfix. Investigating the affected files and their dependencies only."

### Event Logging

Throughout the ticket lifecycle, append entries to the `## Event Log` section of the state file at these natural breakpoints:

| When | What to Log |
|------|------------|
| Classification done | `- [HH:MM] Classified as {type} — loaded {context profile}` |
| Plan approved | `- [HH:MM] Plan approved — {N} files to modify` |
| Existing pattern found | `- [HH:MM] Following pattern from {file} — {what}` |
| AC completed | `- [HH:MM] AC{N} done — {brief description}` |
| Issue hit | `- [HH:MM] Hit issue: {what happened} — {how resolved or investigating}` |
| Workaround applied | `- [HH:MM] Workaround: {what} — should be a pattern?` |
| Debug session opened | `- [HH:MM] Debug session opened: .claude/debug/{slug}.md — {symptom}` (cause-unknown failure, §5.1b) |
| Debug resolved | `- [HH:MM] Debug resolved: {root cause} — see {slug}.md` |
| Tests written | `- [HH:MM] Tests written — {N} files` |
| CI passed/failed | `- [HH:MM] {CI command} — {passed/failed with details}` |

**Do NOT log:** every file read, every grep, every tool call. Only decisions, completions, and problems.

This costs ~10 lines per ticket and gives `/learn` specific material to extract patterns from — especially the "Hit issue" and "Workaround" entries which are the most valuable for pattern files.

For tiers other than Trivial/Bugfix, continue with the full workflow. (The canonical classification is the `Tier:` block saved above — there is no separate `Type:` block.)

## 1.5 Confluence Business Context (Optional)

**Skip this step for:** deps, config, refactor, e2e-test, bug-simple ticket types.
**Run this step for:** feature-frontend, feature-backend, feature-fullstack, bug-complex, security.

**Token budget:** Max 3 search results, max 1 page (300 words). Skip silently if Confluence MCP unavailable.

Extract 2-3 keywords from the Jira ticket summary (drop filler words like "add", "update", "fix", "the").

**Local cache first:** Check if `specs/confluence/mvp/functionalities-index.md` or other local index files at `$WORKSPACE_ROOT/specs/confluence/` contain relevant info. Grep for the keywords:
```bash
grep -i "keyword1\|keyword2" $WORKSPACE_ROOT/specs/confluence/mvp/*.md $WORKSPACE_ROOT/specs/confluence/req/*.md 2>/dev/null | head -10
```
If a match is found with a page ID and summary, use that cached summary as context — no Confluence API call needed.

**If no local match**, search Confluence MVP space:
```
mcp__atlassian__searchConfluenceUsingCql
  cloudId: "your-org.atlassian.net"
  cql: "space.key = MVP AND title ~ \"keyword1 keyword2\""
  limit: 3
```

If results found, read ONLY the top result's first 300 words:
```
mcp__atlassian__getConfluencePage
  cloudId: "your-org.atlassian.net"
  pageId: "{top result ID}"
  contentFormat: "markdown"
```

Store as compact context: `Business context ({page title}): {first 300 words}`

Pass this into Step 3 (Create Plan) as additional context. Do NOT echo the full page content to the conversation.

**If zero results or MCP unavailable, skip silently** — not all tickets have Confluence docs.

## 2. Enter Plan Mode & Investigate

**If CLARIFY_BLUEPRINT was loaded in Step 0.7, SKIP this step.** The blueprint already contains File Placement, Patterns to Follow, API Contract, Dependencies, and Phase Plan. Re-investigating duplicates work clarify already did and adds drift risk. Enter Plan Mode briefly only to present the loaded blueprint to the user for confirmation, then exit to Step 3.

**If no blueprint exists**, enter plan mode with `EnterPlanMode` and investigate the codebase:

1. **Search for existing implementations** in the target repo
   - Use the architecture info from CLAUDE.md to know where to search
   - Look for similar features, components, patterns

2. **Check related repos** (if the feature might have reference implementations elsewhere)
   - Only if relevant — check other repos in `$WORKSPACE_ROOT/`
   - Check API/BFF endpoints in `$WORKSPACE_ROOT/.claude/api-reference/*.json` (for domains with both API versions, check `{domain}-v2-api.json` first — v2 has different endpoint structure than v1)

3. **Identify files to modify/create**

4. **Identify patterns to follow** (from similar existing code or codebase-patterns.md if available)

If the repo has a `ticket-checklist.md`, follow its Phase 1 investigation steps.

## 3. Create Implementation Plan

Write the plan following this format:

```markdown
# Implementation Plan: PROJ-XXXX

## Summary
[What this ticket implements]

## Investigation Findings
- Existing similar code: [path]
- Pattern to follow: [description]
- API endpoint: [exists/needs creation]

## Files to Modify
1. `path/to/file` - [what changes]
2. `path/to/test` - [create tests]

## Implementation Steps
1. [Step] → Depends on: nothing
2. [Step] → Depends on: Step 1
3. [Step] → Depends on: Steps 1, 2

## Questions (if any)
- [Any unclear requirements that need user input]

## Testing Plan
- Unit tests for: [components]
- Test cases: [list]

## Scope Assessment
- Files to create: [N]
- Files to modify: [N]
- Estimated complexity: Low | Medium | High
```

**CRITICAL: Don't Guess - Ask.** When something is NOT defined in the ticket or Figma, ask the user.

## 4. Update Ticket State File

After plan approval, update `{REPO_ROOT}/.claude/tickets/PROJ-XXXX.md`:
- Set Plan status to DONE
- Set Implementation status to IN_PROGRESS
- Fill in Plan Summary with key decisions
- Fill in Decisions Made
- Update Current Focus to first implementation step

## 4.5 Transition Jira Ticket to "In Progress"

Once implementation is about to start (plan approved, ready to code), transition the Jira ticket to **In Progress**. This keeps the board in sync with reality — tickets should not sit in `To Do` while actual work is underway.

**Preferred — MCP Atlassian:**
```
mcp__atlassian__transitionJiraIssue(
  cloudId: "your-org.atlassian.net",
  issueIdOrKey: "PROJ-XXXX",
  transition: { id: "<IN_PROGRESS_TRANSITION_ID>" }   # "In Progress" in your project's Jira workflow
)
```

**Fallback — jira CLI:** `jira issue move PROJ-XXXX "In Progress"`

Notes:
- `<IN_PROGRESS_TRANSITION_ID>` — look up per-project via the jira CLI or `mcp__atlassian__getTransitionsForJiraIssue`, then record it for your ticket project key (e.g. PROJ).
- Skip if the ticket is already in `In Progress`, `Code Review`, `QA`, or `Done`.
- If the recorded id errors, re-fetch with `mcp__atlassian__getTransitionsForJiraIssue` — workflow ids can differ per project.
- `/pr` handles the next transition (Code Review) when the PR is created; `/verify` leaves status alone until PR time.

## 5. Implement

Follow the repo's conventions from CLAUDE.md and codebase-patterns.md (if available).
If the repo has a `ticket-checklist.md`, follow its implementation and testing phases.

**Comment hygiene — apply as you write, don't clean it up afterward.** Default to **NO comment**; names, types, and the commit message carry intent. Add a comment ONLY for a non-obvious WHY / constraint a maintainer genuinely can't infer from the code. **Never** put in a comment: ticket numbers (`PROJ-XXXX`), section/spec refs (`§16`, `NEW-2`), acceptance-criteria refs (`AC3`), bug-letter labels (`Bug C`), or before→after / changelog history — all of that lives in git + the PR. This is the recurring noise complaint ([[feedback_no_bug_letter_comments]]) and is machine-enforced by the **Comment Hygiene Gate** (`/verify` §3.4 and `/pr` §5e), which BLOCKS delivery on a hit — writing it clean now saves a rework pass.

### 5.0 Branching

If a PHASE_PLAN was loaded with Phase 0 = Setup, that phase covers branch creation. Otherwise, ensure a feature branch exists before Step 5.1.

**Worktree isolation (parallel-session guard).** Before creating the branch, check `state/index.json` for OTHER `in-progress` tickets on this repo, and check for working-tree changes you didn't make. If either is true, do NOT branch inside the shared checkout — create an isolated worktree:

```bash
git -C {REPO_ROOT} worktree add ../{repo}-wt/{TICKET_ID} -b <fix|feat>/{TICKET_ID}-{slug} origin/{BASE_BRANCH}
```

Do ALL work for this ticket inside the worktree path, and record `worktree: ../{repo}-wt/{TICKET_ID}` in the state-file frontmatter so `/verify`, `/pr`, and `/resume-ticket` operate there. This mechanically kills the shared-checkout failure classes — a sibling session's commit landing on your branch, and cross-ticket staging surgery ([[feedback_shared_checkout_commit_lands_on_wrong_branch]], [[feedback_shared_checkout_selective_staging]]). After the PR merges, `/ci-check` runs `git worktree remove ../{repo}-wt/{TICKET_ID}`.

### 5.1 Phase-aware execution (when PHASE_PLAN exists)

**When the blueprint defined N phases**, implement them one at a time:

For each phase from 1 to N:
1. Set `## Current Focus` in the state file to `Phase {N} — {Title}`.
2. Mark that phase's row in `## Implementation Progress` as `IN_PROGRESS`.
3. Use `TodoWrite` to break the phase's `Files` and `ACs` into todos.
4. Implement only the files listed for this phase. Touching files outside the phase's `Files` list is a signal that the plan needs updating — pause and surface it.
5. **Scoped checks** — at phase end, run the minimum that validates THIS phase (e.g., `npx eslint {phase files}` + `npx tsc --noEmit` if types changed; `npm test -- {phase test files}` if tests were added). **If the phase touched `e2e/**` (Playwright specs), also run those specs locally — `yarn ci`/Vitest does NOT run Playwright, so a broken or flaky E2E spec passes CI silently otherwise** (frontend repos: `yarn test:e2e {phase e2e specs} --workers=2 --reporter=line`; creds in `.env`, `PLAYWRIGHT_BASE_URL` defaults to deployed dev). Skip the full `yarn ci` until the final verification phase.
6. Append a one-line event: `- [HH:MM] Phase {N} done — {files touched} — checks: {pass/fail}`.
7. Mark the phase's progress row `DONE`. Update Files Modified.
8. **Checkpoint with the user:**
   > "Phase {N} ({Title}) complete. {1-line summary}. Continue to Phase {N+1} ({next title}), or refine this phase first?"

   Wait for `continue` (or equivalent) before starting Phase {N+1}. If the user says `refine` or `--phase {N}`, hand off to `/clarify PROJ-XXXX --phase {N}` for a deepening pass, then re-enter Step 5.1 at the same phase number.

The final phase is always Verify — when it runs, transition to Step 6 logic (full quality checks).

### 5.1a E2E coverage (absorbed `/e2e`, 0.5.0)

E2E coverage is part of the ticket, not a separate command. If the ticket adds or changes a user-facing flow, then during the final Verify phase: extend the nearest existing spec under `e2e/` (or add one — use the repo's `e2e-writer` agent if `{REPO_ROOT}/.claude/agents/e2e-writer.md` exists). Validate locally per the standing rules: `--workers=1 --trace=on` first, headed against dev as the final gate ([[feedback_local_e2e_before_blind_ci]], [[feedback_e2e_verify_headed_locally]]). Skip silently when no user-facing flow changed. Pre-existing spec rot stays non-blocking ([[feedback_e2e_rot_not_blocking]]).

### 5.1b Debug escalation gate (applies to phased AND non-phased flows)

This is the seam where "in between, when something fails, I just fix it" usually swallows the investigation. When something fails mid-implementation — a test goes red for a reason you don't grasp, the app behaves unexpectedly, you catch yourself about to *try something to see if it helps* — apply the one-sentence gate (canonical: `routing.md` → "Bug intake: the cause-known gate"):

- **Can name the cause in one sentence** (typo, wrong import, off-by-one, a prop you can see is missing) → just fix it and log `- [HH:MM] Hit issue: {what} — fixed: {how}` in the Event Log. No debug session; don't over-ceremony a cheap fix.
- **Cannot** → you're investigating, not fixing. Spin a linked debug session instead of guessing inline:
  1. `mkdir -p {REPO_ROOT}/.claude/debug` and create `{REPO_ROOT}/.claude/debug/{slug}.md` (slug from the symptom) using the `/project-debug` state schema — symptom, first 2-3 hypotheses, evidence log. Set its frontmatter `ticket: PROJ-XXXX`.
  2. Test hypotheses in order; record evidence as you go. If `{REPO_ROOT}/.claude/agents/debugger.md` exists, spawn it (per `/project-debug` §4) to keep this implementation context clean.
  3. Cross-link: add `- [HH:MM] Debug session opened: .claude/debug/{slug}.md — {symptom}` to the ticket Event Log.
  4. On root cause: apply the fix, then log `- [HH:MM] Debug resolved: {root cause} — see {slug}.md`. The ruled-out hypotheses stay in the debug file as `/learn` fuel and a regression-test source.

You never have to remember to type `/project-debug` — this gate routes you there from inside the flow you're already running. Keep cheap fixes cheap; capture the hard ones.

### 5.2 Non-phased fallback (when PHASE_PLAN is absent or `skipped`)

Use `TodoWrite` with each AC as a separate item. After completing each AC:
- Mark the AC checkbox in the ticket state file
- Add modified files to the Files Modified section
- Update Current Focus to the next step

No inter-AC checkpoint required — the ticket was simple enough to skip phasing.

### 5a. Capture Screenshots After UI Changes (if supported)

If the repo has a screenshot script at `{REPO_ROOT}/.claude/scripts/capture-screenshot.js`:
```bash
cd {REPO_ROOT} && node .claude/scripts/capture-screenshot.js \
  --url "/path/to/feature" \
  --name "ac1-feature-name" \
  --ticket PROJ-XXXX
```

Then use the Read tool to view the screenshot and verify it visually.

If no screenshot script exists, ask the user to verify UI changes manually.

## 6. Verify

### Step 6.0: AC Achievement Verification

For EACH acceptance criterion:
1. What must be TRUE for this AC to be met?
2. Which file(s) implement this truth?
3. Is the code real? (not stub, placeholder, TODO, empty handler)
4. Is the code wired? (imported, used, rendered — not orphaned)

### Step 6.1: Code Quality

Run quality checks using the commands from the repo's CLAUDE.md:
- Linting command (e.g., `yarn lint`, `npx eslint`, `swiftlint`, etc.)
- Type checking command (e.g., `yarn type-check`, `npx tsc --noEmit`, etc.)
- Check for repo-specific rules from codebase-patterns.md (if available)
- **Comment Hygiene Gate** — linters don't check comment style, so run it explicitly: scan the comments ADDED by this change for ticket #, `§`/`NEW-n`/`ACn` refs, bug-letters, history narration, and reasoning/restating-the-code noise. Canonical gate + grep: `/verify` §3.4. Any hit → strip it (trivial change) and re-run; don't deliver with it in.

### Step 6.2: Run Tests

Run tests using the commands from the repo's CLAUDE.md:
- Run specific tests for modified files
- Run full test suite / CI command
- **If the ticket touched `e2e/**` (Playwright specs):** run the touched specs locally — they are NOT part of `yarn ci` and gate no PR (E2E runs nightly against deployed dev), so this is the only pre-merge signal that the E2E work actually passes. `yarn test:e2e {changed e2e specs} --workers=2 --reporter=line`. A reproducible failure (survives the config's retries) blocks delivery; pre-existing rot in UNCHANGED specs is non-blocking ([[feedback_e2e_rot_not_blocking]]).

If the repo has a verifier agent at `{REPO_ROOT}/.claude/agents/verifier.md`, spawn it.
Otherwise, do the verification inline following the steps above.

Update ticket state file: set Verification to IN_PROGRESS, then DONE.

## 7. Deliver

**DO NOT** run `git commit`, `git push`, or `gh pr create`.

**DO Provide:**

1. **Commit Message:**
   ```
   feat|fix|refactor(PROJ-XXXX): brief description
   ```

2. **PR Description** — use `{REPO_ROOT}/.claude/pr-template.md` if available, otherwise:
   ```markdown
   ## Summary
   [What this PR does]

   ## Ticket
   [PROJ-XXXX](https://your-org.atlassian.net/browse/PROJ-XXXX)

   ## Key Changes
   - [Change 1]
   - [Change 2]

   ## Tests Added
   - [Test file]: [what it tests]

   ## Definition of Done
   - [ ] AC1
   - [ ] AC2
   - [ ] Unit tests added
   - [ ] CI passes
   ```

3. **Files Changed List**
4. **Summary of Implementation**

## 8. Retrospective

Before marking delivered, fill in the **Retrospective** section of the ticket state file. Reflect on the implementation and write honest, specific entries:

- **What went well:** Approaches, patterns, or decisions that worked smoothly (e.g., "Reusing the existing useTicketActions hook saved time", "The codebase-patterns.md lint reminder prevented a CI failure")
- **What went wrong:** Mistakes, wrong assumptions, time wasters (e.g., "Spent 20 min debugging because I forgot to check the BFF endpoint shape first", "Used wrong import path pattern — had to redo 3 files")
- **Surprises about the codebase:** Things that weren't obvious from CLAUDE.md or patterns files (e.g., "MUI DatePicker needs a LocalizationProvider wrapper that isn't documented", "The review status enum has a hidden 'DRAFT' value not in the TypeScript types")

**Keep entries concrete and actionable** — vague entries like "went well overall" are useless for /learn. The goal is to give /learn enough signal to update `codebase-patterns.md` with real lessons.

Update ticket state file: set status to `ready-for-pr`, all phases to DONE.

> `/ticket` never sets `delivered` — that transition belongs to `/ci-check` after the PR actually merges. Setting it here would overwrite the event log. The handoff chain is: `/ticket` (`ready-for-pr`) → `/pr` (`pr-generated`) → `/ci-check` (`delivered`) → `/learn` (`learned`).

</process>

<state_management>

## Ticket State Updates

The ticket state file (`{REPO_ROOT}/.claude/tickets/PROJ-XXXX.md`) MUST be kept current:

| Event | Update |
|-------|--------|
| Plan approved | Plan → DONE, Implementation → IN_PROGRESS, fill Plan Summary |
| AC completed | Check AC box, add files to Files Modified, update Current Focus |
| Phase transition | Update progress table |
| Decision made | Add to Decisions Made |
| Question resolved | Add to Blockers / Questions Resolved |
| Ticket complete | status → ready-for-pr, all phases → DONE (handoff to /pr) |

## State File Lifecycle

1. **Created** when /ticket starts → status: `planning`
2. **Active** throughout implementation → tracks ACs, files, decisions
3. **Ready for PR** when /ticket finishes phase 8 → status: `ready-for-pr`
4. **PR generated** when /pr completes → status: `pr-generated` (set by /pr)
5. **Delivered** when /ci-check confirms merge → status: `delivered` (set by /ci-check)
6. **Learned** when /learn extracts lessons → status: `learned` (set by /learn)

State files are **never deleted** — they remain on disk after `learned` for retro, /status, and future prior-art lookup. `/learn` may rewrite them but does not remove them.

## Related Commands
- Next: /verify → /pr → /learn
- Testing: /test | /e2e
- Context: /qa (related-ticket lookup is built into /clarify Step 1.5)
- If interrupted: /resume-ticket
- Building without ticket: /build
- Patterns: codebase-patterns.md | testing-patterns.md

After handing off, tell the user: *"Ticket marked `ready-for-pr`. Run `/pr` to generate the commit message and PR description. The state file stays on disk through merge and beyond — `/learn` will reuse it later."*

</state_management>

<success_criteria>
- [ ] Target repo detected and config loaded
- [ ] Ticket state file created at `{REPO_ROOT}/.claude/tickets/PROJ-XXXX.md`
- [ ] Codebase investigated (existing implementations, related repos if relevant)
- [ ] Plan created and approved by user
- [ ] All ACs implemented following repo conventions
- [ ] Unit tests written (if applicable to repo)
- [ ] All verification checks pass
- [ ] Commit message and PR description provided
- [ ] Ticket state file updated to `ready-for-pr` (NOT `delivered` — that's `/ci-check`'s transition after merge)
</success_criteria>
