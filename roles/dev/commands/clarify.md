---
name: clarify
version: 0.8.0
model: "opus[1m]"
description: Analyze a ticket — investigate the codebase, recommend file placement and patterns, plan execution phases when complexity warrants, persist the blueprint for downstream commands, and surface only the questions you can't answer yourself.
argument-hint: "PROJ-XXXX [--phase N] [--no-prior-art] [--cross-repo] [--full-history]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Write
  - Task
  - AskUserQuestion
  - mcp__atlassian__getJiraIssue
  - mcp__atlassian__searchJiraIssuesUsingJql
---

<objective>
Pre-implementation analysis for ticket $ARGUMENTS. Investigate the codebase FIRST — find where things
should go, which patterns to follow, which components to reuse, and whether the API contract supports
what the ticket asks for. Draw conclusions from what you find. When the work is non-trivial, produce
a Phase Plan that decomposes implementation into layer/risk-based phases with explicit cross-phase
dependencies and a shared-files map. Only generate PM questions for things you genuinely cannot
resolve from the code.

This is the step BEFORE /ticket. It answers: "Do I know enough to start, and if not, what exactly
do I need to ask?"

**Persistence:** /clarify writes a single artifact, `{REPO_ROOT}/.claude/tickets/PROJ-XXXX-clarify.md`,
which downstream commands (/ticket, /build) read to seed phase progress without re-investigating.
It also still produces the inline `PROJ-XXXX-visual-spec.yaml` when Step 2.5b fires. No other state
files, branches, or commits are created.

**Deepening mode (`--phase N`):** if invoked with `--phase N` after a prior /clarify run, re-investigate
ONE phase tightly — useful when mid-implementation surprises a phase. This is opt-in; the default run
does not re-clarify per phase.
</objective>

<process>

## 0. Detect Target Repository

1. **Parse $ARGUMENTS** for repo hints (e.g., "in addin-fe", "for api-bff")
2. **Check current working directory** — if CWD is inside `$WORKSPACE_ROOT/{repo-name}/` (`$WORKSPACE_ROOT` = the directory that contains all your repos), use that repo. **IMPORTANT:** `$WORKSPACE_ROOT/` itself is NOT a valid target — it's the workspace root. Only match if CWD is at least one level deeper.
3. **If still ambiguous**, list repos and ask:
   ```bash
   ls -d $WORKSPACE_ROOT/*/CLAUDE.md 2>/dev/null
   ```

## 0.5 Setup Auditor — improve this repo's workflow as we go

Before any ticket work, do a fast check of this repo's `.claude/` and docs setup. Every missing piece is an opportunity to improve the workflow — surface it as a one-time prompt, don't nag on later runs.

```bash
echo "### Setup audit for {REPO_NAME}"
[ -f {REPO_ROOT}/README.md ]                        && echo "✓ README.md"                       || echo "✗ README.md — missing"
[ -f {REPO_ROOT}/CLAUDE.md ]                        && echo "✓ CLAUDE.md"                       || echo "✗ CLAUDE.md — missing"
[ -f $WORKSPACE_ROOT/.claude/repo-profiles/{REPO_NAME}.yaml ] \
                                                     && echo "✓ repo profile"                    || echo "✗ repo profile — missing"
[ -f {REPO_ROOT}/.claude/codebase-patterns.md ]     && echo "✓ codebase-patterns.md"            || echo "✗ codebase-patterns.md — missing"
[ -f {REPO_ROOT}/.claude/testing-patterns.md ]      && echo "✓ testing-patterns.md"             || echo "✗ testing-patterns.md — missing"
[ -f {REPO_ROOT}/.claude/ticket-checklist.md ]      && echo "✓ ticket-checklist.md"             || echo "✗ ticket-checklist.md — missing"
[ -f {REPO_ROOT}/.claude/pr-template.md ]           && echo "✓ pr-template.md"                  || echo "✗ pr-template.md — missing"
[ -d {REPO_ROOT}/.claude/agents ]                    && echo "✓ .claude/agents/"                 || echo "✗ .claude/agents/ — missing"
[ -f $WORKSPACE_ROOT/.claude/project-map.md ] \
                                                     && echo "✓ project-map.md"                  || echo "✗ project-map.md — run /project-context"
[ -f $WORKSPACE_ROOT/.claude/stack-connections.md ] \
                                                     && echo "✓ stack-connections.md"            || echo "✗ stack-connections.md — backend stack map missing; FE↔BFF↔Go traversal will be guesswork"
```

Also check **patterns file freshness:**
```bash
if [ -f {REPO_ROOT}/.claude/codebase-patterns.md ]; then
  stamp=$(grep -oE "last-updated: [0-9]{4}-[0-9]{2}-[0-9]{2}" {REPO_ROOT}/.claude/codebase-patterns.md | head -1 | awk '{print $2}')
  [ -n "$stamp" ] || echo "⚠ codebase-patterns.md has no last-updated marker"
  # Warn if older than 45 days
fi
```

**Rules:**
- Never interrupt ticket analysis to set up missing pieces. Surface the findings as a "Setup recommendations" section at the very end of Step 7's output, with **one-liner suggestions** like:
  > "⓵ Create CLAUDE.md for this repo — run `/bootstrap`"
  > "⓶ No repo profile — create `.claude/repo-profiles/{REPO_NAME}.yaml` from `_schema.yaml`"
  > "⓷ `codebase-patterns.md` has no last-updated marker — will get one on next `/learn`"
- If CLAUDE.md is missing AND no repo-profile exists AND this is the first time we've hit this repo, **ask once** whether to bootstrap the repo before continuing. Otherwise proceed with defaults and show the recommendations at the end.

This is the **self-improving workflow** loop: every ticket you run `/clarify` on teaches you which pieces of scaffolding are missing, and offers exact commands to fix them.

## 0.7 Deepening Mode (`--phase N`)

If `$ARGUMENTS` contains `--phase N` (e.g. `/clarify PROJ-6214 --phase 3`):

1. Require a prior clarify artifact at `{REPO_ROOT}/.claude/tickets/PROJ-XXXX-clarify.md`. If missing, abort with: *"No prior clarify found for PROJ-XXXX. Run `/clarify PROJ-XXXX` first to produce the macro plan, then re-invoke with `--phase N`."*
2. Read the Phase Plan section. Confirm phase N exists. If not, list the available phases and stop.
3. **Skip** Steps 1.5, 1.5b, 1.8, 2.5b, 4a, 4b, 4c, 4d, 4e — the macro pass already did those.
4. **Run** Step 3 (Deep Codebase Investigation) scoped to phase N's `Files`, `ACs`, and `Goal` from the macro plan.
5. **Output** ONLY a `## Phase N — Deep Dive` block: refined file list, gotchas surfaced from real grep evidence, open questions specific to this phase's how-to.
6. **Append** the block to `PROJ-XXXX-clarify.md` under `## Deepening` (create the section if absent). Do NOT rewrite the macro plan — phase plans never renumber.

Then stop. The user re-enters the implementation flow with sharper context for phase N only.

If `--phase N` is NOT present, continue with the full flow below.

Load repo config (cheap — always):
- `{REPO_ROOT}/CLAUDE.md` — architecture and conventions
- `{REPO_ROOT}/.claude/testing-patterns.md` if present

**Defer the heavy context loads until AFTER Step 1.2 classifies the tier** (see `$WORKSPACE_ROOT/.claude/routing.md`). Do NOT read these yet — for a **Trivial** ticket (Dependabot, config, copy change) they are never loaded at all, and loading them just adds noise that degrades focus:
- `{REPO_ROOT}/.claude/codebase-patterns.md` (**FULL file**) — load at Step 1.2 for Bugfix (only if the area matches), Standard, and Complex. If `$WORKSPACE_ROOT/.claude/codebase-patterns-shared.md` exists, load it first (shared rules); then the repo file. New patterns from `/learn` live here; if its `<!-- last-updated: YYYY-MM-DD -->` marker is >45 days old, warn "patterns may be stale — consider running `/learn` first".
- `stack-connections.md` — load only if `REPO_TYPE` is backend (`backend-bff`/`backend-go`), OR the ticket mentions a backend domain term (e.g. order, item, invoice, version-pin, override, lambda, dynamo, BFF, ms-{domain} — adapt this list to your stack's domain vocabulary), OR (`frontend-ui`) the ticket implies a backend API change. Walk its §"Domain quick-pick" → 3-layer map; the per-domain "Adding a new operation" recipe IS the plan template, and §"Type-drift hazards" guards multi-layer field assumptions.
- `command-proposals.md` (grep for the ticket's domain) — **Standard/Complex only**:
  ```bash
  grep -B 1 -A 5 -i "{REPO_NAME}\|$(echo $TICKET_SUMMARY | tr ' ' '\n' | head -5)" $WORKSPACE_ROOT/.claude/command-proposals.md 2>/dev/null
  ```
  Surface any domain match as a "Known-issue watch" section.

Store **REPO_ROOT**, **REPO_NAME**, and determine **REPO_TYPE**:
- `addin-fe` → **frontend-ui** (Next.js, React, MUI)
- `web-app` → **frontend-ui** (legacy frontend)
- `api-bff` → **backend-bff** (Node BFF)
- `backend-services`, `shared-go-lib`, `mail-service` → **backend-go** (Go Lambda)
- `ios-app` → **mobile-ios** (Swift)
- `gdocs-addin` → **google-workspace-addin**
- `billing-service` → **backend-service** (standalone)
- Other → infer from `package.json`, `go.mod`, `Podfile`, etc.

## 1. Fetch Ticket

### Option A: Jira ticket ID in $ARGUMENTS (PROJ-XXXX pattern)

Fetch the ticket (try in order):
1. **MCP**: `mcp__atlassian__getJiraIssue` — extract summary, description, acceptance criteria, story points, linked tickets, issue type, assignee
2. **CLI fallback**: `jira issue view PROJ-XXXX --plain`
3. **Ask user**: "Couldn't fetch from Jira. Paste the ticket details."

Also check for an existing ticket state file:
```bash
for dir in $WORKSPACE_ROOT/*/; do
  [ -f "$dir/.claude/tickets/PROJ-XXXX.md" ] && echo "$(basename $dir): $dir/.claude/tickets/PROJ-XXXX.md"
done 2>/dev/null
```
If found, read it for additional context (plan, decisions, files already identified).

### Option B: Ticket pasted directly

Use the text from $ARGUMENTS as-is. Skip Jira fetch.

### Option C: No arguments

Check for active ticket state files:
```bash
for dir in $WORKSPACE_ROOT/*/; do
  ls "$dir/.claude/tickets/"*.md 2>/dev/null
done
```
If found, ask which ticket to analyze. If none, ask the user to provide a ticket ID or paste details.

## 1.1 Already-Landed-Fix Check (run right after fetching — before classifying)

The fix may already be merged. A bug filed today can be fixed the same day, and the fix is
often **folded into a sibling ticket's PR** — so a PR-title search misses it. Run BOTH:

```bash
gh pr list --state all --search "PROJ-XXXX" --limit 20 --json number,title,state,mergedAt,url 2>/dev/null
git -C {REPO_ROOT} log --all --grep="PROJ-XXXX" --oneline -20   # catches fixes folded into another ticket's PR
```
If a commit/PR already implements the ACs, STOP the deep investigation: verify the behavior on the
merged code (goal-backward), report "already implemented by {sha}/PR #{n}", and recommend
verify-and-transition instead of `/ticket`. (PROJ-6489 was filed and fixed the same day — folded into
PROJ-6250 PR #231; `gh pr list` found nothing, `git log --all --grep` found the commit.)

## 1.2 Classify & Route (do this BEFORE loading patterns / spawning agents)

Now that the ticket is fetched, classify its tier using the canonical flowchart `$WORKSPACE_ROOT/.claude/routing.md`. Set **{TIER}** = Trivial | Bugfix | Standard | Complex from the summary, issue type, and FILE MAP. This decision gates every load below — the whole point is to not over-load a capable model with context the work doesn't need.

**If {TIER} == Trivial** (Dependabot / dependency or lockfile bump, version pin, config-only, single copy or text change, env var):
- Do NOT load `codebase-patterns.md`, `stack-connections.md`, or `command-proposals.md`.
- SKIP Steps 1.5, 1.5b, 1.8, 2.5, 2.5b, 3 (codebase-investigator), and 4e (type-duplication scan).
- Emit a one-paragraph blueprint and stop:
  > **Tier: Trivial — no investigation needed.** File(s) to change: {…}. Verification: {repo CI/test command}. Hand to `/ticket` or `/do` for a direct implement → CI → PR pass.
- Persist the artifact with `tier: Trivial`, `phases: skipped`. Done.

**Otherwise** ({TIER} is Bugfix / Standard / Complex): load that tier's context profile from `routing.md` NOW (this is where `codebase-patterns.md` and friends actually get read — lazily, per the load matrix), then continue. Each heavy step below assumes its tier gate from `routing.md`; if a step isn't in this tier's profile, skip it.

## 1.5 Related Tickets (merged from former /related)

Investigate Jira tickets related to this one BEFORE parsing implementation claims, so scope and dependencies inform everything after.

### Fetch related ticket graph (via jira-context-loader agent)

**Prefer the agent.** If `$WORKSPACE_ROOT/.claude/agents/jira-context-loader.md` exists, invoke it:

```
Task(
  subagent_type: "jira-context-loader",
  description: "Load Jira context for {TICKET_ID}",
  prompt: "Load full Jira context for {TICKET_ID}.
    depth: full
    Return the normalized ticket-graph markdown block."
)
```

The agent parallelizes all fetches and normalizes MCP vs CLI output — use its result directly as the "Related Tickets" section below.

**Fallback: inline fetching.** If the agent is not available, execute inline:

**Linked issues** — for each ticket in the "is blocked by", "blocks", "relates to", "duplicates" lists:
```
mcp__atlassian__getJiraIssue  for each linked ticket ID
```
CLI fallback: `jira issue view PROJ-YYYY --plain`

**Epic siblings** — if the ticket has an epic link:
```
mcp__atlassian__searchJiraIssuesUsingJql  jql: "Epic Link = PROJ-EPIC ORDER BY status"
```
CLI fallback: `jira issue list --project PROJ --parent PROJ-EPIC --plain`

**Subtasks** — if this ticket has subtasks, fetch each one.

**Parent** — if this IS a subtask, fetch the parent.

Run all of these IN PARALLEL in a single tool-use block.

### Check local state for related tickets

For each related ticket, check for an existing local state file across repos:
```bash
for dir in $WORKSPACE_ROOT/*/; do
  for tid in {list of related ticket IDs}; do
    [ -f "$dir/.claude/tickets/${tid}.md" ] && echo "$(basename $dir): $tid"
  done
done 2>/dev/null
```

### Identify overlapping code

For each related ticket with a local state file, read its `## Files Modified` section. Flag files that appear in multiple tickets — those are potential merge-conflict or coordination hotspots.

### Output (fold into Implementation Blueprint in Step 7)

```markdown
### Related Tickets
| Ticket | Relation | Status | Local State | Overlap? |
|--------|----------|--------|-------------|----------|
| PROJ-YYYY | blocks | In Progress | addin-fe (implementing) | shares app/_lib/orders-v2/ |
| PROJ-ZZZZ | epic sibling | Done | — | no |

**Blockers:** {list with status — highlight any NOT done}
**Coordination needed:** {tickets actively worked on that touch same files}
**Decisions from related work:** {key decisions lifted from their state files' Decisions Made sections}
```

If a blocker is NOT done, make it a top-priority blocking question:
> "PROJ-YYYY blocks this ticket but is still In Progress. Confirm we can proceed in parallel, or should we wait?"

## 1.5b Prior Art Lookup (local state index)

After fetching the Jira graph (Step 1.5a), query the local state registry for past tickets matching this one's axes. Goal: surface **3 tickets max** of genuinely-relevant prior art, never more. Never read 20 tickets to start planning.

### Preconditions

- `$ARGUMENTS` does NOT include `--no-prior-art` (if it does, skip this entire step)
- Classification from Step 1 produced at least `layer` + `feature_area` for this ticket (otherwise can't query meaningfully — emit a one-line note "prior-art lookup skipped: not enough classification signal" and continue)
- `$WORKSPACE_ROOT/.claude/state/index.json` exists (otherwise run `$WORKSPACE_ROOT/.claude/scripts/state-index-scan.sh --bootstrap` silently first)

### Query

Filter the index with jq. HARD filter (required match):
```bash
INDEX=$WORKSPACE_ROOT/.claude/state/index.json
CROSS_REPO=""
[[ "$ARGUMENTS" == *"--cross-repo"* ]] && CROSS_REPO="1"

jq --arg repo "$CURRENT_REPO" \
   --arg layer "$CURRENT_LAYER" \
   --arg area "$CURRENT_FEATURE_AREA" \
   --arg cross "$CROSS_REPO" '
  .entries
  | map(select(.status != "abandoned"))
  | map(select($cross == "1" or .repo == $repo))
  | map(select(
      ((.tags.feature_area // []) | index($area))
      or (.tags.layer == $layer)
    ))
' "$INDEX"
```

Default (no flag): same-repo hard filter — keeps noise low, surfaces tickets that used the exact same codebase conventions.

With `--cross-repo`: drop the repo filter. Query ALL repos by `feature_area` OR `layer`. Useful when asking "how did we solve auth in addin-fe?" while working in web-app, or "where did we implement optimistic updates anywhere?". This absorbs what would have been a separate `/sibling` command — one flag, not a new command.

Both modes: removes abandoned entries. Expect pool size to drop from 27 to ~5-10 same-repo, or ~8-15 cross-repo.

### Pick the most relevant

From the candidate pool, judge relevance to the current ticket — strongest signals are matching `layer`/`surface`/`atomic_level`, presence of a `## Retrospective` or `## Review Feedback` section, and recency (prefer the last ~60 days; discount `learned` tickets older than ~180 days). For **diversity**, don't surface more than ~2 hits from the same feature_area or more than 1 from the same epic/parent. Default to the **top ~3 picks** to keep the blueprint focused (raise with `--full-history`).

### What to read per pick

Read each pick's `## Retrospective` (and `## Review Feedback`, if present) — that's where the reusable lesson lives. Skim the body only if the retro points at something specific. Surface the takeaway, not the whole ticket.

### Output placement

Fold into the Step 7 blueprint AFTER the Step 1.5a "Related Tickets" table and BEFORE Step 4's Implementation Blueprint. Format:

```markdown
## Prior Art ({N} of {pool_size} candidates)

| Ticket | Repo | Tags | Retro takeaway | Dive deeper |
|--------|------|------|----------------|-------------|
| [[PROJ-5834]] | addin-fe | layer=ui, kind=feature, area=orders-v2 | Used existing DetailPageLayout instead of rebuilding | `cat $WORKSPACE_ROOT/addin-fe/.claude/tickets/[[PROJ-5834]].md` |
| [[PROJ-5878]] | addin-fe | layer=ui, surface=detail-view, area=orders-v2 | Defensive gating prop pattern for AC-specific visibility | `cat .../[[PROJ-5878]].md` |
| [[PROJ-6027]] | gdocs-addin | layer=ui, kind=feature | Google Apps Script sidebar can't be browser-previewed | `cat .../[[PROJ-6027]].md` |
```

### Process lessons (process-ledger read-path)

If `{REPO_ROOT}/.claude/process-ledger.md` exists, grep its `## AUTO:PROCESS-LESSONS` region for entries matching this ticket's class (tier, surface, or feature_area). Append up to 3 matches under the Prior Art table:

```markdown
**Process lessons for this ticket class** (process-ledger.md):
- {imperative "next time do X first" line} — [[PROJ-XXXX]], [[PROJ-YYYY]]
```

These are `/learn` §2.7b's distilled how-we-work-here rules — capturing them only pays off if they surface HERE, at planning time. 0 matches or no ledger → omit silently.

### Noise prevention rules

- **0 matches**: omit the section entirely. No "No prior art found" line.
- **1–3 matches**: show all.
- **4–5 matches**: show top 3 + one-liner: `N more hits — grep state/index.json by feature_area/layer to see all.`
- **>5 matches**: show top 3 + one-liner: `N total — your tags are broad. Narrow with --feature-area or --surface.`

### Overrides

- `$ARGUMENTS` includes `--no-prior-art` → skip Step 1.5b entirely (useful when you know the work is genuinely unprecedented)
- `$ARGUMENTS` includes `--full-history` → raise the default ~3 picks to ~10 and read each retro plus relevant body sections.
- `$ARGUMENTS` includes `--cross-repo` → drop the same-repo hard filter (see Query section). Blueprint header explicitly notes "cross-repo lookup" so the user knows the hits may use different frameworks/conventions.

## 1.8 Design Reference Classification

Before parsing claims, classify the design input. The rebuild plan depends on which of three cases applies:

| Case | Signal | Downstream effect |
|------|--------|-------------------|
| **A. Prototype reference** | Ticket links a `proto/*` branch, or the branch is listed in repo-profile `prototype_branches:` | Step 2.5 extracts interaction code as reference-only. Rebuild plan in atomic order. |
| **B. Design spec (Figma/mockup/screenshots)** | Ticket has Figma link, attached mockups, or screenshots | Decompose the design into atomic levels during planning. Map each region to existing atoms/molecules. |
| **C. No design** | Ticket describes functionality in prose only, no mockup or prototype | Use atomic design as the **abstraction framework**: propose a solution starting from existing atoms; flag any new atom/molecule that would serve future tickets (abstract as you go). |

Store as **{DESIGN_CASE}** ∈ `prototype | spec | none`. The rest of `/clarify` adapts to this value.

## 2. Parse Implementation Claims

Extract every implementation-relevant claim from the ticket. Organize into:

| Category | What to extract |
|----------|----------------|
| **UI/Layout** | Page structure, zones, columns, sections, responsive behavior |
| **Visual/CSS** | Per-state styling (default, hover, focus-visible, active, disabled, loading); border-radius, padding, gap, colors, opacity, box-shadow; z-index expectations; transform/animation timing; dark-mode behavior; narrow-viewport rules (≤450px, ≤768px breakpoints); scroll behavior (which container scrolls, which axis); fixed/sticky positioning expectations |
| **Components** | Named components, widgets, interactive elements |
| **Behavior** | Click handlers, transitions, animations, loading states, error states |
| **Data** | Fields displayed, field sources, computed values, aggregations |
| **Permissions** | Role-based visibility, scoped actions, gating logic |
| **Navigation** | Routes, breadcrumbs, back buttons, deep links |
| **Integration** | API endpoints, webhooks, third-party services |
| **Accessibility** | aria-label, role attributes, focus order, keyboard shortcuts, screen-reader announcements |
| **Scope** | Explicitly in-scope items, explicitly out-of-scope items, gray areas |

For each claim, note whether it is **specific** (actionable as-is) or **vague** (needs investigation).

**Note on Visual/CSS claims:** these are the highest-leakage category — Figma mockups typically capture only the default state, leaving hover/focus/disabled/narrow-viewport implicit. When you see a Visual claim, also check whether ALL relevant states are specified. Missing-state claims become questions in Step 5.

## 2.5 Prototype-Aware Investigation

**Trigger:** the ticket body, attached Jira links, or the parent epic mentions a prototype branch. Detection patterns (case-insensitive):
- Branch names matching `prototype/*`, `spec/*`, `design/*`, `throwaway/*`
- Phrases like "see branch X", "prototype branch", "reference implementation", "locked spec", "from the prototype"
- Screenshots in the Jira ticket annotated with a branch name

Also check `.claude/repo-profiles/{REPO_NAME}.yaml` for a `prototype_branches:` list. Any branch listed there should be treated as reference.

If no prototype reference found, skip to Step 3.

### What to do when a prototype reference is detected

1. **Fetch the branch locally (read-only):**
   ```bash
   git -C {REPO_ROOT} fetch origin {PROTOTYPE_BRANCH} 2>/dev/null
   ```
   Do NOT check it out. Stay on the current branch.

2. **Find the named component(s)** the ticket references (e.g., "the drawer", "summary card"):
   ```bash
   git -C {REPO_ROOT} ls-tree -r --name-only "origin/{PROTOTYPE_BRANCH}" | grep -iE "{keywords}"
   ```

3. **Extract interaction code as reference:**
   ```bash
   git -C {REPO_ROOT} show "origin/{PROTOTYPE_BRANCH}:{path/to/component.tsx}"
   ```
   Capture the layout structure, state transitions, animation timings, and conditional logic.

4. **Surface in the Implementation Blueprint (Step 7) under a dedicated section:**

   ```markdown
   ### Prototype Reference (do NOT copy code — rebuild against main)

   Source branch: `{PROTOTYPE_BRANCH}` @ commit `{short_sha}` (last updated {date})

   | Ticket Claim | Prototype Reference | Key Behavior Notes |
   |-------------|---------------------|-------------------|
   | "Drawer expands on card click" | `app/_lib/compliant/components/Drawer.tsx` | slide-in 300ms, overlay click closes, ESC closes |

   **Rebuild plan:**
   - Real API: swap hardcoded `mock/order.json` for `useGetOrder` hook
   - Real auth: wrap the route in `<RequireScope scope="orders:read">`
   - Real types: replace `any` props with types from `app/_lib/items-v2/types.ts`
   - Tests: the prototype has none — explicit test plan below

   **⚠ Load-bearing assumption:** PM, design, and eng have confirmed this prototype is reference, not code. If unconfirmed, STOP and confirm — this workflow breaks if anyone tries to merge the prototype directly.
   ```

5. **Add to the Questions output (Step 6) a top-priority checkbox:**
   > "Has the team explicitly agreed the prototype is reference-only, not mergeable? If not, that needs to happen before any ticket in this epic starts."

6. **If the ticket looks like the FIRST leaf in a prototype-driven epic** (e.g., it depends on a plumbing/shared-data layer that doesn't exist yet), recommend plumbing first:
   > "This epic appears to be rebuilding from a prototype. Consider doing the shared data + auth + types plumbing BEFORE the leaf tickets — the leaves parallelize once plumbing exists."

### Known failure modes to surface in the blueprint

When the prototype reference is detected, add a one-line watch-list to the blueprint:

```markdown
### Prototype-Spec Watch-List (5 known risks)
1. "Looks done" illusion — remind stakeholders plumbing is 60–80% of real work
2. Prototype rot — prototype branch is {N days old}; diverging from main
3. Backend gap — BFF, auth, S3, retries, rate limits are invisible in the demo
4. Hardcoded types sneaking in — verify real API response matches prototype's JSON shape
5. Tests start at zero — explicit test plan required, don't assume prototype tests survive
```

## 2.5b Visual Spec Extraction

> **Cross-framework / sideload surfaces → hand to the `ui-fidelity` agent (contract mode).** When the design reference is a *different framework* than the target (e.g. the GDocs add-in is the reference for a Word/addin-fe ticket) OR the surface is sideload-only (Word add-in, GDocs add-in, iOS), the CSS-Module grep below under-delivers. Invoke the agent to produce the **target contract in this surface's idiom** + the **live-data hardening list** up front, so gaps are known before coding (this burned PROJ-6603 over 4 QA rounds — [[feedback_design_fidelity_live_data]]):
> ```
> Task(subagent_type: "ui-fidelity", description: "UI contract for {TICKET_ID}",
>   prompt: "ticket_id: {PROJ-XXXX}; repo_root: {REPO_ROOT}; surface: auto; design_reference: {sibling-surface path | Figma | screenshots}; impl_files: {candidate file placement}; locked_decisions: {from clarify}; ledger_path: {REPO_ROOT}/.claude/ui-fidelity-ledger.md; mode: contract")
> ```
> Fold its per-element contract + live-data list into the blueprint and the `visual-spec.yaml`. The mechanical CSS-Module extraction below still runs for same-framework web tickets.
> The agent auto-loads this surface's synthesized **meta-lessons** from the ledger (its Process step 0) — generalizations `/learn` §2.7 distilled from past iteration misses on this surface — and turns them into mandatory contract gates, so recurring UI misses (e.g. unclamped live descriptions, unenumerated states) get caught up front instead of in a 4th QA round.

**Trigger (any of the following — auto-detect, no user flag required):**

- Step 1.8 classified `{DESIGN_CASE}` as `prototype` or `spec` AND Step 2.5 detected a prototype branch reference, **OR**
- Ticket modifies any `*.module.css` file (CSS Module changes almost always carry an implicit visual contract worth locking)
- Ticket touches `app/_lib/word-addin/` or any UI-domain feature folder like `app/_lib/{domain}/components/`
- Ticket has a Figma link in the description, comments, or attachments (Figma → extract states even without a prototype branch)
- Ticket has labels containing `visual-bug`, `ux`, `design`, `QA-blocker`, or `fix-forward`
- Ticket title/description contains visual keywords: `button`, `layout`, `footer`, `header`, `color`, `spacing`, `centered`, `aligned`, `overlap`, `scroll`, `viewport`, `responsive`, `dark mode`

Skip ONLY when `{DESIGN_CASE} = none` AND no UI-domain/CSS-module file is touched AND no visual keywords present in the ticket text.

**Why this step exists:** Step 2.5 captures component STRUCTURE from the prototype but doesn't resolve conditional Tailwind classes / CSS Module rules into a per-state visual contract. Tickets like [[PROJ-6086]] and [[PROJ-6087]] (2026-05-11) shipped with `/verify` HIGH and immediately failed QA because the proto's `bg-blue-300/50` (collapsed) and `border-blue-300` (expanded) classes were never extracted. The CSS contract was on disk; we just never read it. [[PROJ-6088]] / [[PROJ-6089]] (2026-05-15) shipped, failed QA on the QA engineer's visual review, and required a fix-forward — the original visual-spec extraction missed the narrow-viewport Intercom collision and the `overflow-y: auto` visibility-pair gotcha because the trigger was too narrow.

### Algorithm — 4 passes per component

For each component named in the ticket's claims:

**Pass 1 — Source-of-truth resolution.** Choose CSS Modules vs Tailwind:
- If proto has `{component_dir}/styles.module.css`, read it directly.
- Else read `{component_dir}/{Component}.tsx`, extract `className={classNames({...})}` and conditional class objects. Each `{ "class-name": condition }` entry encodes a per-state visual rule.

**Pass 2 — Token / value resolution.** For each Tailwind utility (`bg-blue-300/50`, `border-action-light`):
1. Decompose into prefix + color key + opacity modifier
2. Resolve color key via Tailwind built-in palette → `tailwind.config.*` extensions → `@theme inline` in proto's `globals.css` (v4 pattern)
3. Apply opacity modifier (`/50` → `alpha 0.5`)
4. Map non-color utilities to rem/px via Tailwind reference table

**Pass 3 — Token mapping (proto → develop).** For each resolved value, find the closest existing token in develop's `app/globals.css`:

```bash
grep -nE "^\s*--color-.*:\s*#" {REPO_ROOT}/app/globals.css
```

Build a mapping table. Flag rows with no equivalent as `NEW TOKEN NEEDED` and surface in Step 4's Decisions block so implementation adds tokens before component work.

**Pass 4 — Icons, animations, pseudo-states.** Also capture:
- Right-side icons (most common QA miss): grep for `FontAwesomeIcon`, `<Icon`, inline `<svg` inside JSX header. Capture icon name or full SVG.
- Animations: `transition-`, `duration-`, `@keyframes`, `animation:`. Note property + duration + easing.
- Pseudo-states: `hover:`, `focus-visible:`, `active:`, `disabled:`. Resolve same as Pass 2.
- Disclosure indicators: chevron transforms, arrow rotations.
- Placement on BOTH axes (PROJ-6176 QA-bounce class): record the element's relationship to its anchor sibling vertically (above/below/between which siblings) AND horizontally (own-row vs inline-with-{sibling} on the same row, plus alignment edge). "Above the totals" alone under-specifies — the inline-vs-own-row axis is the one that slips past QA.

### Output

Two artifacts:

1. `{REPO_ROOT}/.claude/tickets/PROJ-XXXX-visual-spec.yaml` — machine-readable spec consumed by `/verify` Step 2.6.
2. `## Visual Spec` section inlined into the ticket state file under `## Plan Summary`, human-readable.

#### YAML format (canonical)

```yaml
spec_version: "1.0"
ticket: PROJ-XXXX
extracted: {ISO timestamp}
proto_branch: {PROTOTYPE_BRANCH}

components:
  - name: {ComponentName}
    proto_source: {path}:{line range}
    impl_target: {expected impl path}
    states:
      collapsed:
        background-color: "rgba(...)"
        border: "..."
        cursor: "pointer"
      expanded:
        background-color: "..."
        border: "..."
    header:
      right_icon:
        kind: "fontawesome-pro-duotone" | "inline-svg" | "lucide"
        name: "{icon-name}"
    placement:
      anchor: "{sibling the element is positioned relative to, e.g. section title}"
      vertical: "above | below | between {siblings}"
      horizontal: "own-row | inline-with-{anchor}; align: left | right"
    animations:
      - selector: "{css selector}"
        property: "transform"
        from: "rotate(-90deg)"
        to: "rotate(0deg)"
        duration: "200ms"

token_map:
  - proto_value: "rgba(147, 197, 253, 0.5)"
    develop_token: "--color-action-light"
    opacity: 0.5
    action: reuse-with-opacity
  - proto_value: "#0353a8"
    develop_token: null
    suggested_name: "--color-action-hover"
    action: NEW_TOKEN_NEEDED
```

#### Inlined state-file section

Append to the state file's `## Plan Summary`:

```markdown
## Visual Spec

Extracted from `{PROTOTYPE_BRANCH}` @ `{short_sha}` (see `.claude/tickets/PROJ-XXXX-visual-spec.yaml`).

**Smoking-gun deltas** (most likely to fail QA if dropped):
1. {component}: {property} {expected value}
2. ...

**New tokens required:** {list from token_map where action = NEW_TOKEN_NEEDED}

**See:** `.claude/tickets/PROJ-XXXX-visual-spec.yaml` for full per-component property table.
```

### Edge cases

- Proto branch unreachable → flag blocker question, skip extraction
- Component name mismatch (proto `PositionAnalysisAccordion` ↔ impl `InDepthAnalysis`) → record in `impl_target` field; ask user if ambiguous
- Tailwind v3 vs v4 — detect from `@theme inline` block presence
- Dynamic values (template literals, computed) → flag `dynamic: true`, skip mechanical comparison
- FontAwesome Pro icons without license → capture name + suggest substitution in `suggested_substitution` field

### Verification handoff

`/verify` Step 2.6 reads `PROJ-XXXX-visual-spec.yaml`. Step 7 clamps confidence if the spec exists but visual comparison wasn't actually performed.

## 3. Deep Codebase Investigation (via codebase-investigator agent)

**Prefer the agent if available.** If `$WORKSPACE_ROOT/.claude/agents/codebase-investigator.md` exists, invoke it via the Task tool with `subagent_type: "codebase-investigator"`:

```
Task(
  subagent_type: "codebase-investigator",
  description: "Investigate {REPO_NAME} for {TICKET_ID}",
  prompt: "Investigate ticket {TICKET_ID} for the {REPO_NAME} codebase.
    repo_root: {REPO_ROOT}
    repo_type: {REPO_TYPE}
    feature_keywords: {keywords from Step 2}
    ticket_claims: {ticket_claims}
    focus: all

    Report back in the structured format defined in your agent spec. Run all searches in parallel."
)
```

The agent is authoritative for Investigations A–F (similar features, file placement, reuse, API surface, interactive patterns, permissions) and saves ~200 lines of re-implementation here.

**Fallback: inline investigation.** If the agent is not available, run the 6 investigations yourself IN PARALLEL — do not execute them sequentially. Spawn a single internal Task call that fires all Glob/Grep/Read tool calls concurrently (multiple tool uses in a single response), and collect all results before synthesizing.

```
Task(
  description: "Parallel codebase investigation for ticket analysis",
  subagent_type: "Explore",
  prompt: "Investigate the {REPO_NAME} codebase ({REPO_TYPE}) for ticket {TICKET_ID}.

    Ticket summary: {summary}
    Key claims: {list of UI/component/behavior/data claims from Step 2}

    **IMPORTANT: Run all 6 investigations in parallel.** Issue all Glob/Grep calls in a single tool-use block, then synthesize the results. Do NOT run them sequentially.

    Investigation 1 — **Similar pages/features**
       Find the CLOSEST existing implementation to what the ticket describes.
       - Ticket says 'detail page' → find ALL detail pages + compare structure
       - Ticket says 'list with filters' → find ALL filtered lists + note pattern
       Report: file paths, layout structure (columns/zones/sections), components used.

    Investigation 2 — **Exact file placement**
       Based on the ticket's feature domain, determine:
       - Which `app/_lib/{{domain}}/` directory this belongs in (frontend) OR which `src/routes/` file (BFF) OR which `lambdas/ms-{{domain}}/` folder (go)
       - Which `app/(web)/` route this maps to (frontend)
       - Where tests should go
       - If the ticket has a FILE MAP, verify paths match the codebase convention

    Investigation 3 — **Reusable components/modules**
       For each UI element or code unit the ticket mentions, check existing implementations:
       - Frontend: search `app/_common/`, `app/_lib/`
       - BFF: search `src/middlewares/`, `src/utils/`
       - Go: search `internal/`, `pkg/`, `shared-go-lib/`
       Report: exact name, file path, props/args, whether it fits.

    Investigation 4 — **Reusable hooks / helpers**
       - Frontend: `app/_common/hooks/`, `app/_lib/{{domain}}/hooks/`, `app/_api/`
       - BFF: `src/hooks/`, util modules
       - Go: `shared-go-lib/` exports
       Report: name, what it does, whether it fits.

    Investigation 5 — **API endpoints & BFF routes** (parallel internal sub-queries)
       a) Check if every endpoint the ticket references exists in swagger:
          grep -i '{{keywords}}' $WORKSPACE_ROOT/.claude/api-reference/*.json
       b) Check BFF route layer (if frontend ticket):
          grep -r '{{route}}' $WORKSPACE_ROOT/api-bff/src/ --include='*.ts' -l
       c) Check Go handler (if backend ticket):
          grep -r '{{endpoint}}' $WORKSPACE_ROOT/backend-services/lambdas/ -l
       Report for each: exists/missing, fields, type mismatches, pending work needed.

    Investigation 6 — **Patterns & permissions**
       a) For each interactive element (kebab menu, drawer, modal, inline editing, status badge,
          filter, pagination), find the existing implementation pattern.
       b) If roles/permissions are mentioned, find how existing features gate access
          (useHasScope, permission checks, role-based rendering, Go middleware, BFF guards).
       Report: which component/middleware, which file, how it's wired.

    ## Output format
    Organize findings by the 6 investigation numbers above. Be specific — file paths,
    line numbers, component names. Flag any ticket claim the codebase doesn't support.
    This report drives the entire analysis, so do not summarize away detail."
)
```

### For multi-repo tickets

If the ticket spans multiple repos (e.g., frontend + BFF + backend), check each:
```bash
# Check if API endpoints exist
grep -i "{endpoint keywords}" $WORKSPACE_ROOT/.claude/api-reference/*.json 2>/dev/null
# Check BFF routes
grep -r "{route}" $WORKSPACE_ROOT/api-bff/src/ --include="*.ts" -l 2>/dev/null
```

### Branch-state pinning for CI/workflow precedent claims

Investigation greps run against whatever branch is checked out — stale answers for
`.github/workflows/`, CI configs, and `scripts/`. When a conclusion claims a CI
gate or precedent exists (or doesn't), read those files pinned to the base branch:
```bash
git -C {REPO_ROOT} fetch origin --quiet
git -C {REPO_ROOT} show origin/{BASE_BRANCH}:{path}   # single file
git -C {REPO_ROOT} grep "{pattern}" origin/{BASE_BRANCH} -- .github/ scripts/
```
If the working tree must be used, print the current branch next to the finding so
staleness is visible, and mark the conclusion "re-verify after Phase-0 pull".

## 4. Draw Conclusions

Based on the investigation, make decisions and recommendations for everything you CAN determine. Don't ask about things the codebase already answers.

### 4a. File Placement Recommendation

Based on existing structure and conventions, recommend exact file paths:

```markdown
### Recommended File Placement

| File | Path | Reason |
|------|------|--------|
| Page component | `app/(web)/library/items/[id]/page.tsx` | Matches existing detail page pattern at `app/(web)/orders-v2/[orderId]/` |
| Feature components | `app/_lib/items-v2/components/` | Domain follows existing `app/_lib/orders-v2/` structure |
| Query hooks | `app/_api/items-v2/` | Matches existing `app/_api/orders-v2/` |
| Types | `app/_lib/items-v2/types.ts` | Standard location per codebase patterns |
| Tests | `__tests__/lib/items-v2/components/` | Mirrors source structure |

**If the ticket has a FILE MAP:** Compare the ticket's proposed paths against your recommendation. Flag any disagreements:
> "Ticket suggests `app/(web)/positions/page.tsx` but the codebase convention is `app/(web)/library/positions/page.tsx` (positions are under the library route group). Recommend using the library path."
```

### 4b. Pattern Recommendations (atomic-design aware)

**Auto-load the Common Visual Pitfalls hub** from `{REPO_ROOT}/.claude/codebase-patterns.md` (the dedicated cluster near the top of the file) when ANY of the visual-spec extraction triggers in Step 2.5b fired. This gives the recommendations below visibility into known visual gotchas (overflow visibility-pair rule, narrow-viewport SDK quirks, scroll-container patterns) WITHOUT loading the full ~5000-line file.

#### 4b.0 Visual / CSS Contract Decisions (when applicable)

When the ticket has Visual/CSS claims from Step 2 OR Step 2.5b fired, output an explicit decisions block BEFORE the atomic-level pattern table:

```markdown
### Visual / CSS Contract Decisions

| Aspect | Decision | Reference / Reason |
|--------|----------|-------------------|
| Component states | default + hover + focus-visible + active + disabled (loading if async) | per visual-spec.yaml; reuse `--color-brand-*` tokens |
| Z-index layer | modal: 1300, drawer: 1200, tooltip: 1500 (from MUI theme) | match existing stacking — never invent new layers |
| Scroll context | `overflow-y: auto; overflow-x: hidden` (always set both per visibility-pair rule) | Common Visual Pitfalls hub |
| Narrow viewport | `useNarrowScreen()` + right-padding 72px on bottom-right content (Word Add-in pane is ≤450px) | Intercom collision pattern |
| Dark mode | inherits via `--background` / `--foreground` tokens; no per-component dark overrides needed | existing pattern |
| Animation | 250ms ease-out for entry; reuse `card-expand` keyframe | existing |
| Accessibility | `aria-label` on every interactive; focus order header → body → action → nav | existing |

**This block prevents implementation from drifting into ad-hoc CSS decisions.** Each row should reference either the visual-spec.yaml, an existing token, or an established codebase pattern.
```

For each UI element or behavior the ticket describes, state which existing pattern to follow — classified by atomic level:

```markdown
### Patterns to Follow (by atomic level)

| Level | Ticket Claim | Existing Pattern | Reference File | Action |
|-------|--------------|-----------------|----------------|--------|
| Atom | "Status pill" | StatusBadge | `app/_common/StatusBadge.tsx` | reuse as-is |
| Atom | "Info icon" | Icon | `app/_common/Icon.tsx` | reuse (variant: `info`) |
| Molecule | "Editable title row" | EditableTitle | `app/_common/EditableTitle/index.tsx` | reuse |
| Molecule | "Form field with error" | FormField | `app/_common/FormField.tsx` | reuse |
| Organism | "Kebab menu" | KebabMenu | `app/_common/KebabMenu/index.tsx` | reuse |
| Organism | "Filter bar" | OrderFilters | `app/_lib/orders-v2/components/OrderFilters.tsx` | generalize to `_common` |
| Template | "Detail page layout" | 2-col sidebar layout | `app/(web)/orders-v2/[orderId]/layout.tsx` | reuse |
| ⭐ NEW Atom | "Priority chip" | — | to create: `app/_common/PriorityChip.tsx` | create in its own ticket (reusable beyond this feature) |
| ⭐ NEW Organism | "Compliant drawer" | — | to create: `app/_lib/compliant/components/CompliantDrawer.tsx` | composes: Drawer atom + Badge atom + FormField molecule |
```

### 4b.1 Ticket Scope by Atomic Layer

Classify the ticket overall:

| Profile | Description | Parallelizable? |
|---------|-------------|-----------------|
| **Pure page assembly** | All atoms/molecules/organisms exist; ticket wires them into a new page | Yes — independent leaf |
| **Organism-new** | New organism composing existing atoms/molecules | Yes if its atoms exist; serial if atoms are missing |
| **Molecule-new** | New molecule (e.g., new form pattern) | Usually yes, but check if atoms are missing first |
| **Atom-new** | New atom (e.g., new input variant, new icon) | **Do this FIRST** — it unblocks every ticket that needs it |
| **Mixed-layer** | Touches multiple atomic levels | ⚠ Split into per-layer tickets for parallelization |

If the ticket is **mixed-layer**, flag it:
> "This ticket touches atoms + organisms. Splitting into (1) atom ticket, (2) organism ticket that uses it, lets the team parallelize leaf work. Recommend scoping down."

### 4b.2 Atomic-First Rebuild / Build Plan

Produce a layered plan the team can execute in order:

```markdown
### Execution order (atomic-first)
1. **Atoms (serial bottleneck)**
   - NEW: `PriorityChip` — add to `app/_common/PriorityChip.tsx` with variants low/med/high
   - NEW: `Icon` variant `info` — extend existing Icon component
2. **Molecules (can start after atoms merge)**
   - NEW: `PriorityField` — PriorityChip + label + helper text
3. **Organisms (can start after molecules merge; parallelizable among themselves)**
   - NEW: `CompliantDrawer` — uses existing Drawer + new PriorityField
   - REUSE: `KebabMenu` — as-is
4. **Template / Page assembly (last)**
   - New page composes: DetailPageLayout + CompliantDrawer + KebabMenu
5. **Tests (final pass)**
   - Atom tests: PriorityChip rendering per variant
   - Molecule tests: PriorityField interaction
   - Organism tests: CompliantDrawer open/close + integration with form
   - Page tests: route renders with real API (mocked in test)
```

### 4b.3 Case-specific guidance

Adapt the output based on **{DESIGN_CASE}** from Step 1.8:

- **Case A (prototype):** The classification above maps prototype components → atomic levels. The Execution order section makes the rebuild plan explicit. Include the "do NOT copy" banner from Step 2.5.
- **Case B (design spec):** Decompose each region of the Figma/mockup into atomic levels. Any region that doesn't map to an existing component is a NEW-atom or NEW-molecule candidate — flag explicitly.
- **Case C (no design):** Propose the solution in atomic terms. For each NEW component, decide: **feature-local** (lives under `app/_lib/{domain}/components/`) or **generalizable** (promote to `app/_common/` so future tickets inherit it). Default to feature-local; promote only when a concrete second use case exists. This is the "abstract as you go" pattern — it keeps the atomic library growing naturally without premature abstraction.

### 4c. API Contract Analysis

For each endpoint the ticket references:

```markdown
### API Contract Status

| Endpoint | Exists? | Source | Fields Available | Frontend Needs | Gap? |
|----------|---------|--------|------------------|---------------|------|
| GET /items | Yes | orders-api.json | id, topic, status, isPublic, tags | All covered | None |
| GET /items/:id/versions/:vid | Yes | orders-api.json | onFound (object), onMissing (object) | onFound as string | ⚠️ Type mismatch — needs normalizer |
| GET /items/:id/distribution | Yes | orders-api.json | order count per version | Matches | None |
| POST /items | Yes | orders-api.json | — | — | ⚠️ DynamoDB — need optimistic update |
```

### 4d. Dependency Check

```markdown
### Dependencies

| Dependency | Status | Impact |
|-----------|--------|--------|
| PROJ-YYYY (linked ticket) | Done / In Progress / To Do | Blocking / Not blocking — reason |
| BFF route for /items | Exists at api-bff/src/routes/items-v2.ts | Ready |
| Go backend endpoint | Exists, deployed to dev | Ready |
| Shared component X | Doesn't exist yet — needs extraction from orders-v2 | Blocking if we want to reuse, not blocking if we duplicate |
```

### 4e. Type Duplication Scan

Run this **BEFORE locking the implementation blueprint.** Catches the most common duplication trap: defining domain types in `app/_api/{service}/api-types.ts` that shadow canonical types already in `app/_entities/`. The rule exists at `codebase-patterns.md:961` ("Use existing types") and is reinforced in the post-[[PROJ-6082]] entry `[Workflow]: grep _entities/ before adding any new domain interface to api-types`. Pattern citations alone don't enforce — `/clarify` MUST run the grep mechanically or the trap recurs ([[PROJ-6082]] lost a full PR cycle to it).

**Process:**

1. Extract every proposed `interface` / `type` name from the plan's "Files to create" + "Files to modify" sections. Use the symbol names, not the file names.

2. For each proposed type `{Name}`, run:
   ```bash
   grep -rEn "^export (interface|type) {Name}\b" \
     {REPO_ROOT}/app/_entities/ \
     {REPO_ROOT}/app/_api/ \
     | grep -v "{this_file}"
   ```

3. Classify each match:
   - **Match in `app/_entities/`** → CANONICAL TYPE EXISTS. Three valid responses, present as options:
     - **Reuse**: `import type { {Name} } from "@/app/_entities/{path}"` and consume directly
     - **Map**: write a mapper at `app/_api/{service}/api-mappers.ts` (reference: `app/_api/orders-v2/api-mappers.ts`) — use this when the wire shape genuinely differs from the canonical
     - **Project**: type the response as `Pick<{Name}, "field1" | "field2">` for callers that consume only a subset
   - **Match in `app/_api/{other-service}/`** → SIBLING-SERVICE DUPLICATE. Almost always a sign one or both should consolidate at the entity layer. Surface as a question.
   - **No match** → clean, proceed.

4. **Output (fold into Implementation Blueprint in Step 7):**

```markdown
### Type Duplication Scan

| Proposed type | Match found | Recommended action |
|---------------|-------------|--------------------|
| `Order` | `app/_entities/orders-v2/order.ts:117` (`OrderV2`) + `:141` (`OrderV2Full`) | Reuse `OrderV2Full` OR project via `Pick<OrderV2Full, "id" \| "name">` |
| `MetricCounts` | none | Proceed |
```

5. **Blocking rule:** if any proposed type matches in `app/_entities/`, do NOT lock the blueprint. Promote to Step 5 as a BLOCKING question:
   > "Found canonical `{Name}` at `_entities/{path}:{line}`. Reuse, map at `api-mappers.ts`, or project? (Picking 'redefine' requires explicit user override; document the reason in Decisions.)"

**Reference implementation of the dedupe pattern (post-[[PROJ-6082]]):**
- `app/_entities/orders-v2/` — canonical layer for order types
- `app/_api/orders-v2/api-mappers.ts` — canonical mapping layer (wire shape → canonical)
- `app/_api/<other-service>/api-types.ts` — what NOT to do; shadow types were removed in a follow-up commit

### 4f. Phase Plan

Decompose implementation into **layer- or risk-based phases**, not AC-per-phase. Real-world phases observed across `addin-fe` tickets ([[PROJ-6082]], [[PROJ-6214]], [[PROJ-5541]]) are slices like `types → hooks → view → tests → ci → verify`, not one-AC-per-slice. Each phase should be atomically shippable inside ONE PR (the user's standing rule: one PR per ticket, never split — phases collapse into ~3 atomic commits at delivery).

#### Skip-phasing heuristic

Skip the Phase Plan and emit a single line `**Phasing skipped:** {reason}` if **all** of the following hold (computed from prior steps' findings):

- AC count ≤ 4
- Single layer touched (UI-only OR BFF-only OR Go-only — not mixed)
- File Placement shows NO `create` rows (edit-only ticket)
- No public hook/component prop/API signature changes proposed

Trivial CSS nudges, dependency bumps, and copy fixes all skip. The persisted artifact still gets written with `phases: skipped` in the frontmatter so /ticket and /build know to fall back to single-pass implementation.

#### When phasing applies

Produce a phase list using these conventions:

- **Phase 0 is reserved for setup** (branch + state file, or rebase). Always present.
- **Final phase is verification** (yarn ci / lint / typecheck / smoke).
- **Middle phases follow the work's natural risk gradient** — usually types → hooks → view → tests, but adapt to the ticket. For visual-spec tickets: tokens → atoms → molecules → page wire-up. For backend tickets: types → handler → wire → tests.
- **Each phase carries a time budget** (e.g., 5min / 15min / 45min). Time budgets are estimates, not contracts, but they force honest sizing — a 4-hour phase is too big.
- **Cross-phase dependencies are explicit** (`depends on: Phase 2`).
- **Cross-cutting concerns are pre-assigned** (a11y → Phase 3; error states → Phase 2). Never floating.

#### Output format (deterministic — /ticket parses this)

```markdown
## Phase Plan

### Phase 0 — Setup (5 min)
**Goal:** Branch + state file
**ACs:** —
**Files:** —
**Depends on:** —

### Phase 1 — {Title} ({time budget})
**Goal:** {one sentence}
**ACs:** {AC IDs covered, e.g. 1.1, 1.2}
**Files:** {comma-separated paths, or "—"}
**Depends on:** {Phase numbers, or "—"}

### Phase 2 — {Title} ({time budget})
...

### Shared files (touched by >1 phase)
| File | Phases | Note |
|------|--------|------|
| {path} | 1, 2 | Type added in 1, consumed in 2 |

### Cross-cutting (pre-assigned, not floating)
- {concern} → Phase {N}
- {concern} → Phase {N}

### Rationale
{2-3 sentences explaining why these boundaries — what made the cut-points natural}
```

#### What NOT to put in the Phase Plan

- Per-phase pattern recommendations (that's Section 4b, already covered)
- Per-phase open questions (those go to Section 6, scoped at ticket level)
- Per-phase re-investigation (that's `--phase N` deepening mode, user-triggered)
- One PR per phase (the user explicitly does NOT want this — one PR per ticket)

The Phase Plan is the **execution sequence**, not a re-statement of the blueprint. Keep it tight.

### 4g. E2E Blast Radius (repo-aware — skip silently if no e2e)

Compute, at plan time, **which existing e2e specs cover the surfaces this ticket will change**, so the dev knows the spec impact before writing code (a removed copy string or renamed route a spec still asserts is a guaranteed break — surface it now, not at CI).

**Gate 1 — tier.** Skip this entire section for **{TIER} == Trivial** (already short-circuited at Step 1.2). For Bugfix / Standard / Complex, continue.

**Gate 2 — repo has e2e.** Resolve `e2e.enabled` from `$WORKSPACE_ROOT/.claude/repo-profiles/{REPO_NAME}.yaml`. If the profile is silent on `e2e`, auto-detect (a `playwright.config(.ts|.js)` + a `test:e2e` script + a spec dir). If not e2e-enabled, **emit nothing** — no "no e2e" line, no blast-radius table. Backend / no-e2e repos hit this gate and silently no-op. (Typically only frontend repos — e.g. `addin-fe` and `gdocs-addin` — are e2e-enabled.)

**When both gates pass:**

1. Read `e2e.spec_dir` from the profile — **never hardcode `e2e/`** (`addin-fe` = `e2e/`; `gdocs-addin` = `test/e2e/`).
2. Run the blast-radius idiom defined canonically in the repo's `testing-patterns.md` → **"## E2E repo-awareness, blast-radius & skip contract"**. Do NOT re-derive the grep recipe here — that section owns the four surface classes (route literals + `*Path`/`*Base`/`*_URL` consts; user-visible COPY, especially REMOVED copy a spec still asserts; `data-testid` values; API/SSE endpoint paths in `page.route("**/...")`). For /clarify the "diff" is the *planned* change set: the File Placement rows (4a), proposed route/copy/testid/endpoint changes from the Step 2 claims, and any rename or removal the ticket implies.
3. Grep `{spec_dir}` for each planned surface and emit `affected_specs` with `file:line` + the matched token.

Surface in the Step 7 blueprint:

```markdown
### E2E Blast Radius
Spec dir: `{spec_dir}` (from repo profile) · {N} affected spec(s)

| Spec (file:line) | Surface this ticket changes | Matched token | Risk |
|------------------|-----------------------------|---------------|------|
| `e2e/<area>/<flow>.spec.ts:58` | "Add item" primary action (was "Create item") | `getByText("Create item")` | guaranteed break — spec asserts REMOVED copy |
| `e2e/analysis/analysis.spec.ts:120` | route `/v1/analysis` (was `/word-addin/analysis`) | `page.route("**/word-addin/analysis")` | guaranteed break — route renamed |

**Coverage gap:** {if a critical user flow GAINS new behavior with no covering spec, name the flow and recommend `/e2e {feature}` — see Step 6 / ticket-checklist DoD.}
```

If both gates pass but **zero** specs are affected, emit a single line: `**E2E Blast Radius:** no specs in `{spec_dir}` cover the changed surfaces.` (This is honest signal for an e2e repo, distinct from the silent no-op of a non-e2e repo.)

The affected_specs list feeds the ticket-checklist Definition-of-Done item ("update or note the e2e specs your change affects") and, on a new-behavior coverage gap, the /e2e routing recommendation.

## 5. Identify Remaining Ambiguities

After conclusions, check what's STILL unresolved. Only things the codebase can't answer:

For each remaining ambiguity:
- **Clear** — resolved by codebase investigation → no question needed
- **Concluded** — you made a reasonable decision based on patterns → state your conclusion, no question needed
- **Genuinely ambiguous** — multiple valid interpretations, no pattern to follow → generate a question

### Ambiguity categories (adapt based on REPO_TYPE):

**For frontend repos:**
- Visual/Layout without mockup AND no similar existing page
- **Visual state spec missing** — Figma shows the default state but no hover/focus-visible/active/disabled/loading mocks. (Very common — Figma exports rarely cover every interaction state.) Auto-generate a question asking the PM to either confirm "use existing component conventions for interaction states" OR provide per-state specs.
- **Narrow-viewport behavior unspecified** — ticket is for the Word Add-in OR a responsive-layout-impacting feature, but the ticket has no explicit ≤450px or ≤768px expectations. Especially flag if the feature has right-edge content (Intercom collision risk).
- **Scroll context unstated** — ticket says "scrollable list" or "scrollable details" but doesn't specify WHICH container scrolls vs WHICH container is fixed. Ambiguity here causes the visibility-pair-rule bugs documented in `codebase-patterns.md`.
- **Z-index / stacking ambiguity** — ticket implies a modal/drawer/tooltip but doesn't say what should be ON TOP of what. Map to MUI theme z-index scale if applicable.
- Component behavior where multiple patterns exist and ticket doesn't specify which
- Conditional logic with unnamed roles/states
- Data fields the UI needs that no API provides
- **Accessibility unspecified** — interactive elements introduced but no aria-label / focus-order / keyboard-shortcut spec. Default to "follow existing pattern" unless the PM wants something custom; flag if the feature is genuinely novel.

**For backend repos:**
- API contract shape not specified and no swagger definition
- Error handling behavior not defined
- Auth/permission requirements not enumerated

**Always check:**
- Scope boundaries — features mentioned but not in ACs
- Dependencies — things that don't exist yet

## 6. Generate Questions (Only for Genuinely Unresolved Items)

For each genuinely ambiguous item, write a question that:

1. **States what the ticket says** (or doesn't say)
2. **States what you found in the codebase** and what conclusion you drew
3. **Offers a concrete assumption the PM can confirm or reject**
4. **Is answerable in one sentence**

### Priority classification:

| Priority | Criteria |
|----------|----------|
| **Blocking** | Cannot start without this. Multiple valid interpretations lead to different implementations. |
| **Important** | Made a reasonable assumption, but risk rework if wrong. |
| **Nice to have** | Will default to existing pattern. Just confirming. |

### If the ticket is clear

If investigation resolved everything — say so:

> "This ticket is clear enough to start. I've mapped all files, identified all patterns, verified API contracts. No questions needed — recommend running `/ticket PROJ-XXXX` directly."

Do not manufacture questions.

## 7. Present Output

### Output 1: Implementation Blueprint (for you)

```markdown
## Ticket Analysis: PROJ-XXXX — {summary}

### Quick Facts
{issue type} | {story points} pts | {REPO_NAME} ({REPO_TYPE})
Tier estimate: {Trivial | Bugfix | Standard | Complex}

### File Placement
| File | Path | Reason |
|------|------|--------|
| ... | ... | ... |

### Patterns to Follow
| Ticket Claim | Pattern | Reference File |
|-------------|---------|----------------|
| ... | ... | ... |

### Components to Reuse
| Component | Path | Fits? |
|-----------|------|-------|
| ... | ... | ... |

### API Contract
| Endpoint | Status | Gap? |
|----------|--------|------|
| ... | ... | ... |

### Dependencies
| Dep | Status | Blocking? |
|-----|--------|-----------|
| ... | ... | ... |

### Conclusions (decisions I made)
1. {Decision}: {reasoning based on codebase evidence}
2. {Decision}: {reasoning}

### Phase Plan
{from Section 4f — full block if phasing applies, or single line `Phasing skipped: {reason}`}

### E2E Blast Radius
{from Section 4g — table of affected specs + any coverage gap; OMIT this heading entirely if the repo is not e2e-enabled (silent no-op)}

### Remaining Questions
{N} total: {blocking} blocking, {important} important, {nice} nice to have
(Or: "None — ticket is clear, ready for /ticket")

### Recommended Next Step
- If no questions: `/ticket PROJ-XXXX`
- If blocking questions: Send Slack message below, then `/ticket` after answers
- If only nice-to-have: `/ticket PROJ-XXXX` now, defaults stated above
```

### Output 2: Slack Message (only if there are questions)

If all ambiguities were resolved by investigation, skip this output entirely.

If questions remain, present inside a code block for copy-paste:

```markdown
Hey [PM name], I'm picking up PROJ-XXXX ({summary}) and want to make sure I build this right.

I've investigated the codebase and here's what I'm planning — just need a few confirmations:

**Need before I start:**
1. {Blocking question with concrete assumption to confirm/reject}

**Want to confirm my approach:**
2. {Important question with what you'll default to}

**Minor — will default unless you say otherwise:**
3. {Nice to have with stated default}

Happy to hop on a quick call if easier, but wanted to try async first. Thanks!
```

**IMPORTANT:** Output the Slack message as raw text inside a code block — not formatted by Claude Code — so the user can copy it exactly as-is.

## 7.5 Persist Output (always — single artifact)

Write the blueprint to `{REPO_ROOT}/.claude/tickets/PROJ-XXXX-clarify.md`. This is the ONE artifact downstream commands read. Use the Write tool. If the file exists from a prior run, overwrite it (the macro plan is regenerated end-to-end; per-phase deepening uses `## Deepening` instead — see Step 0.7).

Schema:

```markdown
---
kind: blueprint
status: blueprint
ticket: PROJ-XXXX
repo: {REPO_NAME}
generated: {ISO 8601 timestamp}
clarify_version: 0.4.1
phases: {N} | skipped
phasing_skip_reason: {only if phases = skipped}
visual_spec: {path to PROJ-XXXX-visual-spec.yaml if Step 2.5b fired, else "—"}
---
```

`kind: blueprint` + `status: blueprint` are load-bearing: the state registry indexes the file as a terminal blueprint (prior-art source, `archived: true`) instead of a `ticket/status: unknown` zombie. The upsert script also infers blueprint from the `*-clarify` filename, so legacy files without this frontmatter still index correctly.

```markdown

## Quick Facts
{from Output 1}

## File Placement
{table}

## Patterns to Follow
{table}

## Components to Reuse
{table}

## API Contract
{table}

## Dependencies
{table}

## Conclusions
{numbered list}

## Phase Plan
{full block from Section 4f, OR single line `**Phasing skipped:** {reason}`}

## E2E Blast Radius
{full block from Section 4g — affected specs table + coverage gap, OR the zero-affected single line; OMIT this section entirely when the repo is not e2e-enabled}

## Remaining Questions
{numbered list with priorities, OR "None — ticket is clear"}
```

**Do NOT persist** the Slack message (it's ephemeral, copy-paste-only) or the conversational "Want me to adjust anything" prompt.

After writing, confirm to the user with the file path:
> "Persisted blueprint to `{REPO_ROOT}/.claude/tickets/PROJ-XXXX-clarify.md`. /ticket and /build will read this — no re-investigation needed downstream."

After presenting both outputs and confirming persistence, ask:
> "Want me to adjust anything, or should I proceed to `/ticket PROJ-XXXX`?"

</process>

<guidelines>

## Investigation First, Questions Last

The core philosophy: **exhaust what the codebase can tell you before asking anyone anything.**

If the codebase has a clear pattern → follow it, don't ask.
If the codebase has two patterns → pick the better one and state your choice.
If the codebase has nothing → THEN ask.

Most "ambiguities" in tickets are actually answerable by reading existing code. The PM doesn't need to tell you which layout to use if there's exactly one detail page pattern in the codebase. They DO need to tell you what happens when a user has no permissions if no existing feature handles that case.

## Tone Guidelines for PM Questions

- **Collaborative, not accusatory.** "I want to make sure I build this right" not "your ticket is missing details."
- **Show your work.** Reference specific files, components, existing patterns. This builds PM confidence that you're not asking lazy questions.
- **Offer defaults.** "I'll follow the Contracts detail page layout unless you say otherwise" is better than "What layout should I use?"
- **Respect PM time.** Group questions by priority so they can answer blocking ones first and defer the rest.
- **Don't over-ask.** If the codebase has a clear pattern and the ticket doesn't contradict it, follow the pattern.

## When NOT to Generate Questions

- The ticket has a Figma link with full mockups → visual questions are answered
- The ticket references a specific existing page as the model → follow that model
- The codebase has exactly one way to do what the ticket describes → just do it
- The "ambiguity" is really just an implementation detail that's your job to decide → don't ask
- You can make a reasonable default and the rework risk is low → state the default, move on

## Multi-Repo Awareness

When a ticket spans repos:
- Check API contracts in `.claude/api-reference/` against what the frontend needs
- Flag mismatches between what the UI expects and what the API provides
- Note if BFF routes exist for the endpoints the frontend will call
- If a Go microservice endpoint is needed but doesn't exist, that's a dependency blocker

</guidelines>

<success_criteria>
- [ ] Ticket fetched (via MCP, CLI, state file, or user paste)
- [ ] All implementation claims extracted and categorized
- [ ] Codebase investigated THOROUGHLY — similar features, file placement, reusable components, hooks, API contracts, BFF routes, patterns
- [ ] File placement recommended with reasoning
- [ ] Pattern recommendations given with reference files
- [ ] API contract analyzed — gaps and type mismatches flagged
- [ ] Dependencies checked — blocking vs non-blocking
- [ ] Conclusions drawn for everything the codebase can answer
- [ ] Phase Plan emitted when complexity warrants (or `Phasing skipped: {reason}` line when it doesn't)
- [ ] E2E Blast Radius computed for e2e-enabled repos on non-Trivial tickets (affected specs + coverage gap); silently omitted for non-e2e repos and Trivial tier
- [ ] Questions generated ONLY for genuinely unresolved items
- [ ] Every question references codebase evidence and offers a confirmable assumption
- [ ] Implementation blueprint presented
- [ ] Blueprint persisted to `{REPO_ROOT}/.claude/tickets/PROJ-XXXX-clarify.md` (Step 7.5)
- [ ] Slack message generated only if questions exist
- [ ] If ticket is clear — said so, recommended /ticket directly
</success_criteria>

## Related Commands
- After clarification: /ticket (start implementing — reads `PROJ-XXXX-clarify.md` directly)
- Deepen one phase mid-implementation: `/clarify PROJ-XXXX --phase N` (Step 0.7)
- Context: related-ticket lookup is built into this command (Step 1.5)
- Business context: Confluence via MCP/search when a space is configured in the repo profile
