---
name: learn
version: 0.6.0
description: Extract lessons from completed tickets AND the current conversation (auto-detected, both in one pass) and update repo pattern files.
argument-hint: "[repo-name] or blank for all repos (--session = conversation-only; never required)"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Write
  - Edit
  - Agent
  - AskUserQuestion
---

<objective>
Scan delivered tickets across ALL repos (or a specific repo), collect retrospectives, extract patterns,
and update each repo's `codebase-patterns.md` (and optionally `testing-patterns.md`) with new entries.
This is the feedback loop that makes all other commands smarter over time.

**Since 0.3.1, /learn has an actuator:** it may APPLY small modifications to existing command files
itself — §0.3 LAND-NOW (queue side) and §5.6 APPLY-NOW / COMPILE-TO-CHECK (capture side) — always
behind an explicit shown-diff approval, never silently. Earlier versions were capture-only: proposals
accumulated at +12/week with a 14% landing rate because nothing in the loop was allowed to land them.
Capture-time triage + bounded in-run landing is the fix. Proposals are always modifications to
EXISTING commands, never new commands.

**Multi-repo by default:** When no repo is specified, scan ALL repos for delivered tickets and process
them together. A single sprint may produce tickets across addin-fe, api-bff, and backend-services
— learn from all of them at once. Patterns go into their respective repo's pattern files.

**Per-ticket reflection (absorbs /retro's questions):** /learn owns the per-ticket retro now — it's the
command you actually run. §1.5 is **tier-gated** (Trivial/Dependabot → skipped) and **evidence-drafted**:
instead of asking you to compose "what went well/wrong" from a blank page, Claude drafts the answers from
the session and you just confirm or correct. It adds the dimension the old retro lacked — a **collaboration
reflection** that explicitly answers *"why did understanding what you wanted take longer than it should
have?"* and converts each friction into a durable `feedback_*` memory so it doesn't recur.

**Ticket Closeout (own-work symmetry):** /learn's primary job is pattern-EXTRACTION, but it also now
FINALIZES each ticket's own documentation. At mark-learned (§5) it (a) refuses to flip a ticket to
`learned` while its phase table is mid-flight or its Retrospective is empty — the integrity gate — and
(b) writes an `AUTO:CLOSEOUT` region into the state file with the ticket's Outcome + Health, computed per
[[ticket-outcome-spec.md]] (the same derivation `/project-context` uses for teammate dossiers). This
closes the asymmetry where teammates' tickets got a rich Outcome+Health dossier but your own delivered
tickets got only a `status: learned` stamp. Own tickets are firsthand, so the Closeout states cause
directly — no "inferred" hedge.

**Obsidian Integration:** This command uses `[[wiki links]]` when writing pattern entries and ticket
state files. It also connects related tickets to each other and to topic hub pages, strengthening
the knowledge graph across tickets and learned patterns.
</objective>

<process>

## 0.3 Proposal-Aging Gate (runs FIRST, every write-capable invocation)

**This is the close-the-loop mechanism.** `/learn` is excellent at *generating* improvement proposals into `command-proposals.md` but historically never *acted* on them — only 3 of 94 were ever marked landed, and the old "every 5th run / >50 proposals" reconciliation trigger was dead (no run counter exists, and it only looked at `Status: OPEN`, which is the youngest cohort). This gate replaces that trigger with an **unconditional, age-derived sweep** at the top of every run.

**Why the gate gained an actuator (0.3.1):** the 0.3.0 gate could only *record* landings — LAND required evidence the change already existed, and editing command files was forbidden (§5.6's old rule). So for a valid-but-unlanded proposal, LAND was unavailable by construction, KILL was dishonest, and DEFER cost one date stamp. Result, measured 2026-06-11: **74 DEFER stamps, 0 gate-driven landings, queue at 94 OPEN growing +12/week.** The fix is effort-symmetric verdicts: **LAND-NOW** applies small diffs in-run (behind explicit approval), DEFER is **capped at 2**, and aged proposals that never recurred get KILLed — recurrence, not the Impact label, is the survival signal (Impact labels had zero historical correlation with landing).

### Step A — find aged proposals (deterministic pre-pass)

A "block" is delimited by `### [YYYY-MM-DD]` headers (NOT `---` rules, NOT `**Status:**` lines — there are 94 blocks but only ~31 status lines). The **created date is the bracket date**. A **missing `**Status:**` line counts as aged-OPEN** — this is critical: ~63 pre-schema blocks have no status and are the real dead weight; scoping to `Status: OPEN` only would re-create the bug. A proposal is **aged** when its effective age ≥ 21 days (matching the observed "83% dead at 21d") and its state ∈ {OPEN, NO-STATUS}. `ADDRESSED`/`STALE` are terminal — skip them.

BSD/zsh-safe pre-pass (this Darwin box has no GNU `date -d`, and `status` is a read-only zsh builtin — do not use it as a loop var):

```bash
PROPOSALS=$WORKSPACE_ROOT/.claude/command-proposals.md
today=$(date +%s)
awk '
  /^### \[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\]/ {
    if (hdr!="") print hdr "\t" (st==""?"NO-STATUS":st) "\t" (rev==""?created:rev) "\t" revn
    created=substr($2,2,10); hdr=$0; st=""; rev=""; revn=0; next
  }
  /^\*\*Status:\*\*/   { st=$2 }
  /^\*\*Reviewed:\*\*/ { rev=$2; revn++ }
  END { if (hdr!="") print hdr "\t" (st==""?"NO-STATUS":st) "\t" (rev==""?created:rev) "\t" revn }
' "$PROPOSALS" | while IFS=$'\t' read -r title pstate effdate revn; do
  { [ "$pstate" = "OPEN" ] || [ "$pstate" = "NO-STATUS" ]; } || continue
  edate=$(date -j -f %Y-%m-%d "$effdate" +%s 2>/dev/null) || continue
  age=$(( (today - edate) / 86400 ))
  [ "$age" -ge 21 ] && printf '%s\t%s\t%s\t%s\n' "$age" "$pstate" "$revn" "$title"
done | sort -rn | tee /tmp/aged-proposals.tsv | head -15
N=$(wc -l < /tmp/aged-proposals.tsv)   # total aged BEFORE the cap — needed for the carry-over report
```

Effective date = the latest `**Reviewed:**` date if present (a DEFER snooze, below), else the created date. The third column (`revn`) is the **defer count** — how many times this proposal has already been snoozed; ≥2 means it is at the defer cap (Step B). **Cap at 15 per run, selected oldest-first** (the `tee` above captures the full count `N` before `head` truncates), then **process them grouped by target command** — landing is command-file-shaped, and one edit often closes several incident-shaped proposals at once. If `N > 15`, this is NOT a silent truncation — report it: "Swept 15 of {N} aged proposals; {N-15} carry to the next run."

### Step B — pre-classify each aged proposal (Opus does the work)

For each aged proposal (you're on Max — fan out one sub-agent per distinct target command for speed), read the target command file named in the proposal's `**Target:**` line (older entries: infer from Suggestion/title) and grep for landing evidence (a section title, a keyword from the Suggestion, a comment citing the proposal). Assign a recommended verdict:

- **LAND** — evidence the change is **already** implemented in the command (it landed in some earlier session). → flip to `**Status:** ADDRESSED YYYY-MM-DD — <command-file>§<section>`. This is bookkeeping, not work.
- **LAND-NOW** — not yet implemented, but the fix is **mechanical**: ≤15 changed lines, ONE target command file, no new schema/flow design. → draft the exact diff and carry it into Step C for approval. On approval, APPLY the edit to the command file in this run, then flip to `**Status:** ADDRESSED YYYY-MM-DD — <command-file>§<section> (landed by /learn)`. **Cap: 3 LAND-NOW applications per run** (keeps runs bounded); excess stays OPEN with its defer count unchanged. Historical basis: 12 of the 16 proposals that ever landed were exactly this ≤15-line mechanical shape.
- **KILL** — superseded, contradicted by current command logic, no longer relevant, **or aged 21d+ with no recurrence** (`**Occurrences:**` < 2 and no `**Last seen:**` sighting since filing). Recurrence is the survival criterion — a real gap gets hit again; a one-off never does. → flip to `**Status:** STALE YYYY-MM-DD — <reason>`. STALE is **reversible**, never a deletion: if the signal recurs later, the §5.6 dedupe revives the entry (flip back to OPEN, bump `**Last seen:**`). Nothing is lost.
- **DEFER** — still valid, design-shaped (not LAND-NOW eligible), AND has **fewer than 2 prior `**Reviewed:**` stamps** (the `revn` column from Step A). → keep `**Status:** OPEN`, stamp `**Reviewed:** YYYY-MM-DD` (won't re-trigger for 21 days). **Defer cap: at 2 prior stamps DEFER is no longer available** — the verdict must be LAND-NOW (draft the diff even if it's near the 15-line bound) or KILL. The cap exists because an uncapped DEFER is free while every other verdict costs work, so the gate otherwise converges to all-DEFER (observed: 74 stamps, 0 landings).

### Step C — one forced decision, then apply

Present a compact verdict table (age | defers-so-far | target command | recommended verdict | one-line reason), with **every LAND-NOW diff shown in full**, then a SINGLE `AskUserQuestion`: **"Apply these {N} verdicts as recommended / Let me adjust some / Skip aging this run."** On "adjust", walk only the ones they want to change. On apply:

1. Perform the approved **LAND-NOW edits first** (Edit the target command files; after each, confirm the file still has intact frontmatter and balanced section headers).
2. Rewrite each swept block's `**Status:**` line in place (and **backfill a status line on NO-STATUS blocks**). Never touch `ADDRESSED`/`STALE` blocks.

This makes "0 STALE" impossible to fake AND makes landings actually happen in-run: a 21d+ proposal must end up ADDRESSED (recorded or applied), STALE, or DEFER-reviewed at most twice. Log to the §6 summary: `aging: {applied} applied now, {recorded} recorded as landed, {killed} killed, {deferred} deferred ({at_cap} hit defer-cap), {carried} carried over`.

## 0.5 Session Learning (auto-detected — no flag required)

`/learn` **always** mines the current conversation for lessons in the same pass as it scans delivered tickets — never require `--session` (standing rule: [[feedback_learn_auto_detects_mode]]). Auto-detect which sources have signal: if there are delivered tickets, process them; if the current conversation contains substantial work (QA, debugging, exploration, decisions), extract from it too; do both when both apply. `--session` is now only an optional hint meaning "conversation-only, skip the ticket scan" — its absence must NOT disable conversation learning.

Conversation learning is especially valuable after:
- QA sessions where you tested multiple tickets live
- Debugging sessions where you discovered codebase quirks
- Exploration sessions where you learned about architecture
- Any session that produced insights not tied to a specific delivered ticket

### How it works:

1. **Detect target repo(s):** Check CWD. If inside a sub-repo of `$WORKSPACE_ROOT/{repo-name}/`, use that repo. If at workspace root, ask:
   ```
   AskUserQuestion: "Which repo(s) should these learnings apply to?"
   Options: [list detected repos with CLAUDE.md]
   ```

2. **Ask the user what they learned** using AskUserQuestion (4 questions, all optional):
   - "What patterns or gotchas did you discover in this session?" (codebase patterns)
   - "Any codebase surprises or undocumented behavior?" (architecture insights)
   - "Any testing insights — tools, automation limitations, test strategies?" (testing patterns)
   - "Anything else worth remembering for future sessions?" (catch-all)

   The user can answer any combination. Empty answers are skipped.

3. **Classify learnings** into categories:
   - **Pitfalls to avoid** → `codebase-patterns.md`
   - **Patterns to codify** → `codebase-patterns.md`
   - **Undocumented behavior** → `codebase-patterns.md`
   - **Testing insights** → `testing-patterns.md`
   - **Playwright/E2E insights** → `testing-patterns.md`

4. **Draft entries** in the same format as ticket-sourced learnings:
   ```markdown
   ### [Category]: [Pattern Name]
   [What to do or avoid, with specific details]
   _Source: session YYYY-MM-DD_
   ```

5. **Check for duplicates** against existing pattern files. Skip entries that already exist.

6. **Present for approval** — show proposed additions. Ask: "Apply these updates?"

7. **Apply if approved** — append entries to the appropriate pattern files.

8. **Skip to Summary** (step 6 of the main flow).

---

## 0. Scan for Delivered Tickets (Multi-Repo)

Scan ALL repos for delivered tickets by default. If $ARGUMENTS specifies a repo name, limit to that repo.

```bash
for dir in $WORKSPACE_ROOT/*/; do
  repo=$(basename "$dir")
  tickets=$(grep -l 'status: delivered' "$dir/.claude/tickets/"*.md 2>/dev/null)
  if [ -n "$tickets" ]; then
    count=$(echo "$tickets" | wc -l | tr -d ' ')
    echo "$repo: $count delivered ticket(s)"
    echo "$tickets"
  fi
done
```

Display the results:
```
Found delivered tickets:
  addin-fe: 3 tickets ([[PROJ-5835]], [[PROJ-5873]], [[PROJ-5878]])
  api-bff: 1 ticket ([[PROJ-5901]])
  backend-services: 1 ticket ([[PROJ-5920]])

Processing all 5 tickets across 3 repos.
```

If $ARGUMENTS specifies a repo (e.g., `/learn addin-fe`), filter to that repo only.

If NO delivered tickets found anywhere, tell the user: "No delivered tickets found in any repo. Complete tickets with `/ticket` → `/pr`, then `/ci-check` marks them `delivered` after the PR merges."

For each repo that has delivered tickets, load its config:
- Read `{REPO_ROOT}/CLAUDE.md` for current conventions
- Read `{REPO_ROOT}/.claude/codebase-patterns.md` if it exists
- Read `{REPO_ROOT}/.claude/testing-patterns.md` if it exists

## 1. Collect Delivered Tickets

Find all ticket state files with `status: delivered` (tickets with `status: learned` are automatically excluded since grep only matches `delivered`):

```bash
grep -l 'status: delivered' {REPO_ROOT}/.claude/tickets/*.md 2>/dev/null
```

As a safety check, after collecting files verify none already have a `learned_date` field — skip any that do.

If none found, tell the user: "No delivered tickets with retrospectives found in {REPO_NAME}. Complete some tickets with /ticket first — the retrospective section gets filled at delivery."

Read each delivered ticket file. Extract:
- Ticket ID, summary, and repo name
- The **Event Log** section — the richest source of patterns. Look for:
  - "Hit issue:" entries → become **pitfalls to avoid**
  - "Workaround:" entries → become **patterns to codify**
  - "Following pattern from:" entries → confirms existing patterns are being used
  - Time between events → reveals which phases are slow (estimation insights)
- The **Retrospective** section (what went well, what went wrong, surprises)
- The **Decisions Made** section (architectural choices worth remembering)
- The **Files Modified** section (to understand which areas of the codebase were touched)
- The **Review Feedback** section (from `/review-comments`) — what reviewers caught:
  - "Kept" entries → patterns the team enforces in code review
  - "Disagreed" entries → potential pattern conflicts or gaps in documentation
- The **Classification** section — ticket type and what context was loaded
- The **Obsidian Links** topic (e.g., `[[playbooks-v2]]`) — used to connect related tickets

### 1.5 Retrospective + Collaboration Reflection (tier-gated, evidence-drafted)

This is where the per-ticket reflection lives — the questions `/retro` used to ask, moved here because this is the command you actually run. Two rules keep it low-friction: it's **tier-gated** (skip the noise) and **evidence-drafted** (Claude proposes the answers from the session; you react, you don't compose from a blank page).

**(a) Tier gate.** Read the ticket's `tier` (or judge the conversation):
- **Trivial** (Dependabot, config/version bumps, one-line fixes) → **skip reflection entirely.** Nothing to explain; go straight to extraction.
- **Standard / Complex** ticket, OR a substantive conversation-mode session (§0.5) with real back-and-forth → run the reflection below.

**(b) Draft from evidence — don't interrogate.** Before asking anything, assemble the answers yourself from what actually happened:
- **Technical retro** (what went well / wrong / surprised) — from the Event Log (`Hit issue:` / `Workaround:`), Decisions Made, rework commits, and the `AUTO:CLOSEOUT` Outcome (QA bounces, `CHANGES_REQUESTED`).
- **Collaboration reflection (the part that was missing)** — explicitly answer **"where did understanding what you wanted take longer than it should have, and why?"** Mine the session + state file for the signals:
  - repeated `/clarify` rounds, scope corrections, or the user re-stating ("no, I meant…", "you missed v1", a caught-it moment),
  - a QA bounce / `CHANGES_REQUESTED` that traces back to a misread requirement,
  - turns spent before the first *correct* action.
  Self-diagnose the cause honestly (ambiguous AC? an assumption I should have verified? a repo/pattern I didn't know? context I should have asked for up front?). This is about *my* performance understanding you — not the code. If the ticket genuinely went smoothly, say so — don't invent friction.

**(c) Present pre-filled; you confirm or correct.** Show the drafted retro + the collaboration finding via `AskUserQuestion` with the draft as the recommended option, so you react in one step ("yes" / "close, but it was actually X" / "skip"). Never present a blank set of questions.

**(d) Convert friction into an improvement (the point of all this).** For each confirmed collaboration friction, propose a concrete, durable fix so it doesn't recur:
- a `feedback_*` **auto-memory** ("how to work with me") — trigger + corrected behavior + the *why* — e.g. "when a ticket names v1 AND v2, implement both, don't descope to one" (many existing `feedback_*` memories are exactly this),
- or a `codebase-patterns.md` entry / `command-proposals.md` item if it's a process or tooling gap (e.g. `/clarify` should have surfaced X).
Show the proposed memory/pattern; save only on approval (per §4 / the no-auto-write rule).

**(e) Write back, then extract.** Put the confirmed answers into the ticket's `## Retrospective` (technical) plus a short `Collaboration:` note, then proceed to §2. If reflection was skipped (Trivial), note it. If the user says "skip", proceed without it but record that it was skipped.

## 2. Analyze & Cluster Lessons

Group the extracted lessons into categories:

### From Event Log "Hit issue:" entries → **Pitfalls to avoid**
- These are the highest-value entries — real problems encountered during real work
- Look for the same issue appearing across multiple tickets (recurring pattern)
- Look for issues that took a long time to resolve (time wasters that a pattern rule could prevent)
- Example: "Hit issue: MUI DatePicker not rendering — missing LocalizationProvider" → pattern: always wrap DatePicker

### From Event Log "Workaround:" entries → **Patterns to codify**
- Workarounds that should become standard practice
- If the same workaround appears in 2+ tickets, it's definitely a pattern

### From Event Log "Following pattern from:" entries → **Pattern validation**
- Confirms existing patterns are being used — don't add these as new entries
- But if a pattern was followed and it DIDN'T work, that's a signal to update the pattern

### From "What went wrong" (retro) → **Additional pitfalls**
- Broader than event log — includes process issues, not just code issues
- Look for wrong assumptions about the codebase

### From "What went well" (retro) → **Patterns to reinforce**
- Approaches that should become standard practice
- Reusable code/hooks/components that others should know about

### From "Surprises" (retro) → **Undocumented knowledge**
- Codebase quirks not in CLAUDE.md or existing patterns
- Hidden dependencies, implicit contracts, or gotchas

### From "Collaboration Reflection" (§1.5) → **feedback memories + process fixes**
- Each confirmed intent-understanding friction becomes a durable improvement, NOT a code pattern: a `feedback_*` auto-memory ("how to work with me") capturing the trigger + corrected behavior + the *why*, or a `command-proposals.md` item if a command should have caught it.
- This is the lane that turns "it took too long to understand what I wanted" into something that changes next time.

### From "Decisions Made" → **Architectural precedents**
- Design decisions that set precedent for future work
- Trade-offs that were evaluated and resolved

### From "Review Feedback — Kept" → **Team-enforced conventions**
- These are the highest-confidence patterns — a real person reviewed the code and said "change this"
- If the same feedback appears across multiple tickets, it's definitely a team convention
- Patterns sourced from review feedback should note: `_Source: PR review — enforced by {reviewer}_`

### From "Review Feedback — Disagreed" → **Pattern gaps or conflicts**
- If you disagreed with a reviewer and had a good reason, the existing patterns may need clarification
- If the same disagreement recurs, it's a signal that the team hasn't aligned on this convention

### From "Classification" → **Classification accuracy**
- Was the ticket type correct? Did it load the right context?
- If a ticket was classified as bug-simple but turned out to be bug-complex, the classification heuristics may need updating

### From an E2E-fix ticket (e2e-enabled repos) → **E2E drift taxonomy + suite health**
- If this ticket fixed broken/flaky/skipped e2e specs, route it through **§2.6 E2E Drift Capture** (gate on the repo being e2e-enabled first): classify each fix into the drift taxonomy and stamp suite skip-rate/failed-count. The taxonomy entry is a one-liner under the canonical testing-patterns section, NOT a full pattern card.
- Skip silently for repos that aren't e2e-enabled — most repos have no e2e.

## 2.5 Identify Patterns to Retire

**Target the work with the latest metric snapshot.** Read the most recent `.claude/metrics/*.json` to focus this pass where it matters:
```bash
curr=$(ls -1 $WORKSPACE_ROOT/.claude/metrics/[0-9]*.json | tail -1)
python3 -c "import json; d=json.load(open('$curr'))['metrics']; \
print('pattern_specificity:', sorted(((r['ratio'], r['repo']) for r in d['pattern_specificity']))); \
print('memory_integrity:', d['memory_integrity'])"
```
- The repo with the **lowest `pattern_specificity` ratio** has the vaguest patterns — prioritize tightening or retiring its entries first.
- If `memory_integrity` shows orphans / broken pointers / stale `project_*` memories, note it and suggest `/memory-lint` at the end.

**Goal: keep `codebase-patterns.md` from growing monotonically.** Healthy /learn deletes about as often as it adds. Without this step the file becomes a write-only ledger and `/clarify` loads dead weight.

For each repo whose patterns file you're about to update, scan the *existing* file for deletion candidates and mark them in the diff alongside additions.

### Candidates to retire

A pattern entry should be **retired** when any of these is true:

1. **Stale source ticket** — `_Source: [[PROJ-XXXX]]_` references a ticket that merged >90 days ago AND no newer ticket has cited it (no other entry, no event log "Following pattern from:" reference).
2. **Superseded by a more specific entry** — a later entry on the same topic is more concrete (names a real file, function, or PR) than the older one. Keep the specific one, drop the vague predecessor.
3. **Code reality changed** — the pattern names a file/function/import that no longer exists. Verify with `grep` or `Glob` before deletion. If the rename is the lesson, rewrite — don't delete and re-add.
4. **Contradicted by current behavior** — the pattern says "X causes Y" but recent tickets show "X is fine, do it". The newer ticket's lesson invalidates the older one.
5. **Pure process commentary** — entries that are PM/process narrative rather than codebase patterns (e.g., "PM conflict resolution"). Move to `command-proposals.md` or delete; do not keep in `codebase-patterns.md`.

### How to scan

For each repo's existing `codebase-patterns.md`:

```bash
# 1. List all _Source: PROJ-XXXX_ references and their ages
grep -nE '_Source: \[\[PROJ-[0-9]+\]\]_' {REPO}/.claude/codebase-patterns.md

# 2. For each cited ticket, check whether it's referenced anywhere else (cross-cite)
# If only one entry cites it AND ticket >90d old → candidate for retirement

# 3. Spot-check 3 random "specific" patterns: confirm cited file/function still exists
```

### How to apply

**Do not delete silently.** When presenting updates to the user (Section 4), include a separate **"Patterns to Retire"** block alongside the additions:

```markdown
### Patterns to Retire (3)

- ❌ `[Category]: Old Pattern Name` (line 142) — source [[PROJ-5102]] merged 2025-12-04 (>90d), no recent citations, contradicted by [[PROJ-6128]] entry below.
- ❌ `[Hook]: useFooLegacy` (line 287) — `app/_common/useFooLegacy.ts` was deleted in [[PROJ-6045]]. Pattern is dead code reference.
- ❌ `[Process]: PM conflict resolution` (line 391) — process narrative, not a codebase pattern. Moving to `.claude/command-proposals.md`.
```

The user must approve retirements the same way they approve additions. If they disapprove, leave the entry untouched.

### Healthy ratio

Track `additions : retirements` per /learn run. If you ran 10 times and retired nothing, the system is regressing into a write-only log. Aim for **roughly 1 retirement per 5 additions** as a long-term floor — most runs will be 0, but bursts of cleanup should happen when stale sources accumulate.

## 2.6 E2E Drift Capture (e2e-enabled repos only — gate first, then classify)

**Gate before anything.** This sub-section runs ONLY when the ticket's repo is e2e-enabled. Resolve `e2e.enabled` from the repo-profile at `$WORKSPACE_ROOT/.claude/repo-profiles/{repo}.yaml`; if the profile is silent, auto-detect (a `playwright.config(.ts|.js)` + a `test:e2e` script + a spec dir). Not e2e-enabled → **skip this entire sub-section silently** (no note, no friction) and continue. The full detection idiom and the spec-grep mechanics live in `addin-fe/.claude/testing-patterns.md` → **"## E2E repo-awareness, blast-radius & skip contract"** — cite that section; do not re-derive the logic here. Always read `spec_dir` from the profile; never hardcode `e2e/` (e.g. the gdocs-addin repo uses `test/e2e/`).

**(a) Is this an e2e-fix ticket?** Detect from the diff/Files-Modified + Event Log: the ticket touched `{spec_dir}` specs, OR an Event Log entry / retro names a failing/skipped spec, OR the work was "fix the broken/flaky/skipped e2e suite." If none of these, skip to §3. (A frontend ticket that merely *changed product code* an e2e suite happens to cover is NOT an e2e-fix ticket — only classify when the fix WAS to the specs or to the spec/code contract.)

**(b) Classify the fix into the E2E drift taxonomy.** Map each fix to a taxonomy bucket. The canonical bucket list is whatever the testing-patterns "E2E repo-awareness, blast-radius & skip contract" / drift-taxonomy section defines; the recurring buckets observed this cycle are:
- **route/path versioning** — a ROUTE literal or `*Path`/`*Base`/`*_URL` const moved (e.g. `/word-addin/analyze` → `/v1/analyze`); spec asserted the old path.
- **copy drift** — a user-visible string changed or was removed and a spec still asserts the old copy (REMOVED copy a spec asserts = guaranteed break; e.g. "Ask about your document" → "Product Assistant", "Create Playbook" → "Add Playbook").
- **transport migration** — request mechanism changed (e.g. GET-poll → SSE) and the spec's `page.route("**/...")` / wait shape no longer matches.
- **mock timing** — eager-init vs lazy mock setup; the mock wasn't installed before the surface read it.
- **selector/markup drift** — header class-selectors → semantic markup; a CSS/`data-testid` selector the spec used disappeared.
- **data-scale assumption** — list/fixture size changed (e.g. a 1000-playbook list now needs name-search to reach an item).
- **false-green skip guard** — drift was HIDDEN by a `test.skip` or an `isVisible().catch(()=>false)` guard rather than fixed; the lesson is the *un-skip*, not just the assertion. (Note the suite-health impact in step (c).)

If a fix doesn't fit a bucket, add it as a new bucket in the taxonomy section (don't force-fit).

**(c) Append the lesson to the taxonomy section — don't start a new pattern card.** Add a one-line, spec-anchored entry under the matching bucket in the testing-patterns drift-taxonomy section (the section under the canonical "E2E repo-awareness, blast-radius & skip contract" heading). Format:
```markdown
- **{surface/spec}** — {old token} → {new token}; fixed in `{spec_dir}{spec}:{line}`. {1-line why}.
_Source: [[PROJ-XXXX]]_
```
This append goes through the normal §4 approval batch (shown before write) and the §5 apply path — it is NOT auto-written. Append the bucket entry under the canonical **"## E2E drift taxonomy"** heading in testing-patterns.md (detection/skip rules live under **"## E2E repo-awareness, blast-radius & skip contract"**; the Suite-health stamp lives under the taxonomy section — see (d)). Never fabricate those headings from here — if either is missing, report it rather than re-creating a second copy.

**(d) Stamp suite health as a trend signal.** For the e2e-enabled repo, capture the suite's skip-rate + failed-count so drift hidden as false-green stays visible run-over-run (the live un-caught drift this cycle was a `test.skip`-masked "Create Playbook" assertion at `playbooks-v2-move-positions.spec.ts:58`). Resolve `spec_dir`/`run_command` from the profile; do NOT run a `sideload_only: true` suite (e.g. the gdocs-addin real-API tier) — for those, only count statically and note "not run (sideload_only)". Static counts (no run needed):
```bash
# resolve SPEC_DIR from the repo-profile (never hardcode e2e/)
SPEC_DIR={spec_dir}; REPO=$WORKSPACE_ROOT/{repo}
total=$(grep -rE "\b(test|it)\(" "$REPO/$SPEC_DIR" 2>/dev/null | wc -l | tr -d ' ')
skipped=$(grep -rE "\b(test|it|describe)\.skip\(" "$REPO/$SPEC_DIR" 2>/dev/null | wc -l | tr -d ' ')
guard=$(grep -rE "isVisible\(\)\.catch\(\(\)\s*=>\s*false\)" "$REPO/$SPEC_DIR" 2>/dev/null | wc -l | tr -d ' ')
echo "skip-rate: $skipped explicit skips + $guard soft-skip guards / $total specs"
```
Record the snapshot as an HTML comment at the top of the testing-patterns drift-taxonomy section (or update the existing one), so the trend is diffable:
```markdown
<!-- e2e-suite-health: repo={repo} date=YYYY-MM-DD specs={total} skips={skipped} soft-guards={guard} failed-last-run={N or 'n/a — not run this pass'} -->
```
Report the delta vs. the previous stamp in §6 as a health signal: "addin-fe e2e: skip-rate {old}→{new}, failed {old}→{new}." A skip-rate that climbs while failures drop is the false-green pattern (drift being skipped, not fixed) — flag it explicitly, don't read it as improvement. `failed-count` is only meaningful when the suite was actually run this pass (CI/local); otherwise stamp `n/a`.

## 2.7 UI-Iteration Synthesis (the meta-learning loop — UI repos only)

This is the **abstraction step**: turn the per-ticket UI iteration captures (`/verify` §8.5) into **synthesized, surface-keyed generalizations** that the `ui-fidelity` agent reads on every future UI ticket (its Process step 0) — and compute the iteration KPI that proves the loop works. Gate: skip silently for repos with no `ui-fidelity-ledger.md` and no `ui-iteration` event lines.

### (a) Collect this cycle's captures
For each UI repo, read `{REPO}/.claude/ui-fidelity-ledger.md` `## AUTO:ITERATION-LOG` plus any `ui-iteration` Event-Log lines in delivered tickets not yet logged. Append the latter into `AUTO:ITERATION-LOG` (dedupe by PROJ-id). Exclude `rounds=unrecorded` from everything below — absence is never success.

### (b) Cluster + synthesize (the "be more abstract" step)
Cluster log rows by **`(surface, correction-class)`**. For any cluster that is **≥2 distinct tickets OR has any single incident at `rounds≥4`**, draft/refresh a meta-lesson — a forward-looking gate rule that none of the source incidents stated individually — and fold the matching `feedback_*` UI memories (the visual-fidelity family) in as provenance. Write it into the ledger's `## AUTO:META-LESSONS` region:
```markdown
### [surface={surface} · cluster={class}] {one-line generalization}
{imperative gate instruction the agent applies BEFORE coding}
Provenance: [[PROJ-XXXX]], [[PROJ-YYYY]] ({N} incidents, {sum} rounds)
Confidence: {HIGH if ≥3 incidents or any 4+, else MED} · mean_rounds_at_synth={X.X} · first_synth=YYYY-MM-DD · last_reinforced=YYYY-MM-DD
```
This is the FIRST `/learn` output that makes an AGENT smarter, and it sidesteps the §5.6 "command-file targets only" rule because the agent reads the ledger at runtime — the agent file itself is never edited. **Honest ceiling:** this generalizes WITHIN the pre-named correction-classes; it does NOT discover a brand-new latent root cause the vocabulary doesn't name (that is a separate, larger cross-corpus synthesis build — flag it, don't fake it here).

### (c) Iteration KPI — the causal, per-class number
Compute mean `rounds` per `(surface, correction-class)` over a trailing window (most-recent 3 vs prior 3 per key). `rounds=99` (still-not-right) is excluded from the mean and counted as an open-failure tally per class. BSD/zsh-safe (ISO dates sort lexically; no GNU `date` needed):
```bash
LEDGER={REPO}/.claude/ui-fidelity-ledger.md
awk '/^- 20[0-9][0-9]-/ { s=c=r=""; for(i=1;i<=NF;i++){
    if($i~/^surface=/)s=$i; if($i~/^rounds=/)r=substr($i,8); if($i~/^correction=/)c=$i }
    if(r+0>0 && r+0<99){ k=s" "c; sum[k]+=r; n[k]++ } }
  END{ for(k in sum) printf "%s\tmean=%.1f\tn=%d\n", k, sum[k]/n[k], n[k] }' "$LEDGER" | sort
```
Stamp the result as an HTML comment at the top of `AUTO:META-LESSONS` (diffable, same idiom as §2.6 suite-health) and surface the delta in §6. Unlike the repo-level metrics (which §5.6.5 says cannot attribute causally), this KPI HAS a per-class join key (`surface × correction`) and is causally readable: the correction-class that caused the pain is the one whose round-count you watch fall. A class that stays flat or climbs means its meta-lesson isn't working — actionable, not vanity.

All of (b)'s writes go through the normal §4 shown-before-write approval batch — never auto-write. Retire a meta-lesson whose class KPI has been flat-low (≤2) for the last 3 windows (the pain is gone) — fold this into the §2.5 retire pass so the ledger doesn't grow write-only.

## 2.7b Process Synthesis (all repos — the PRIMARY /learn output)

§2.7 generalized beyond UI. This is what /learn is *for*: distilling **how work goes in this project** — steps, sessions, iterations, where friction concentrates — not accumulating code patterns (§3 is now recurrence-gated and secondary).

**Input:** each delivered ticket's `## Process Summary` block, written mechanically by `/pr` §8. Because capture happens at PR time, tickets whose chats were closed without /learn lose NOTHING — this section reads everything since the last run.

**(a) Log.** Append one line per newly-delivered ticket into `{REPO}/.claude/process-ledger.md` under `## AUTO:PROCESS-LOG` (create file + region if absent; dedupe by PROJ-id):
`- YYYY-MM-DD PROJ-XXXX class={tier or ticket-class} sessions={N} phases={N} fix_iter={N} debug={n|slugs} days={N}`

**(b) Cluster + distill.** Cluster by ticket class (tier, surface, or feature-area from the state-file tags). For any cluster with **≥2 tickets** where the numbers say something ("visual tickets here average 3+ rounds; the cause is live-data shapes", "BFF tickets are 1-session but bounce on lint", "tickets that skipped /clarify average 2× fix_iterations"), write/refresh a process lesson under `## AUTO:PROCESS-LESSONS` — an imperative "next time, do X first" rule with provenance `[[PROJ-ids]]`, same format discipline as §2.7(b). These lessons are the "how to do things in THIS project" knowledge; `/clarify` prior-art and future sessions cite them.

**(c) KPI.** Mean `fix_iterations` and `sessions` per class, trailing 3 vs prior 3 — same awk idiom as §2.7(c). A class whose numbers don't fall means its lesson isn't working.

Same rules as §2.7: shown-before-write, never fabricate missing fields (`unrecorded` is excluded from means), retire lessons whose class KPI stays flat-low for 3 windows.

## 3. Draft Updates

### For `codebase-patterns.md`:

**Recurrence gate (mirror of §5.6 DROP):** a lesson is codified as a pattern entry on its **SECOND occurrence**, not its first. A first-occurrence lesson stays in the ticket state file (findable via the index + `/clarify` prior-art); when the same failure-class recurs in a later ticket, THAT is the filing trigger — cite both tickets. Exceptions (may file on first occurrence): the lesson is mechanically checkable (goes to §5.6 COMPILE-TO-CHECK instead of prose anyway), or the user explicitly asks to codify it. This is what stops the pattern file from becoming "a lot of new changes without much sense" — recurrence is evidence of generality; a single incident is an anecdote.

Read the existing file (if any). Draft new entries that:
- **Don't duplicate** existing patterns — check before adding
- **Are specific and actionable** — not vague advice
- **Include the "why"** — so future sessions know when to apply them
- **Reference the ticket** — e.g., "(learned from `[[PROJ-1234]]`)" — always wrap PROJ IDs in `[[]]` for the Obsidian graph
- **Stay ≤ 8 lines per entry** — the rule, the why, the source. The full war story lives in the ticket state file; the entry links to it via `[[PROJ-XXXX]]`. A 5,800-line pattern file stops being read; short entries keep it loadable. If the lesson is mechanically checkable, it should ALSO be compiled to a check (§5.6 COMPILE-TO-CHECK) — the entry then cites the check.

Format each new entry as:

```markdown
### [Category]: [Pattern Name]
[What to do or avoid, with specific details]
<!-- Learned from [[PROJ-XXXX]] -->
_Source: [[PROJ-XXXX]]_
```

**For UI component patterns in frontend-ui repos**, extend `[Category]` with the atomic level so `/clarify` can surface them correctly in future tickets. Format:

```markdown
### [Atom]: StatusPill — variants + accessibility baseline
Accepts `variant: 'low' | 'med' | 'high'`. Always pair with aria-label. Use for any status indicator; do NOT create per-feature pills.
_Source: [[PROJ-6143]]_

### [Molecule]: PriorityField — composes StatusPill + Label + HelperText
Use when a form needs priority selection. Lives under `app/_common/`. Do NOT inline the composition per feature.
_Source: [[PROJ-6143]], [[PROJ-6200]]_

### [Organism]: CompliantDrawer — drawer pattern for compliant-review flow
Composes Drawer atom + PriorityField molecule + action buttons. Feature-local under `app/_lib/compliant/components/`. If a second caller appears, promote to `_common`.
_Source: [[PROJ-6078]]_

### [Template]: TwoColumnDetailLayout — sidebar + main
Layout scaffold for any detail page. Reuse via `layout.tsx` in the route group.
_Source: [[PROJ-5878]]_
```

Rules:
- Levels: **Atom | Molecule | Organism | Template | Page**.
- If the pattern is a pitfall or convention that isn't a component (e.g., "always memoize selectors"), keep the old `[Category]: ...` format (no atomic level).
- `/clarify` reads the classified index when recommending which components to reuse vs. create.

The `[[PROJ-XXXX]]` wiki links let Obsidian connect pattern entries back to their source tickets in the graph view. If a pattern was discovered across multiple tickets, link all of them: `_Source: [[PROJ-5580]], [[PROJ-5501]]_`.

### For `testing-patterns.md` (if testing-related lessons exist):

Same approach — add testing-specific patterns learned. Use the same `[[PROJ-XXXX]]` wiki link format in source references.

**E2E-fix lessons are the exception to the pattern-card shape:** if §2.6 produced drift-taxonomy entries, they append as one-liners *under the canonical drift-taxonomy bucket* (the section under "## E2E repo-awareness, blast-radius & skip contract"), not as standalone `### [Category]:` cards — and the suite-health stamp is an HTML comment, not a pattern. Carry those §2.6 outputs into the §4 approval batch as-is; don't reformat them into cards.

### For `business-context.md` (if domain knowledge was learned):

Some lessons aren't about code — they're about WHY things work the way they do. Check for:
- "Hit issue: didn't understand why X needs Y" → business rule not documented
- "Workaround: had to ask PM about the expected behavior" → domain knowledge gap
- "Surprise: the API returns X because of business rule Y" → should be in business-context.md

Update `$WORKSPACE_ROOT/.claude/business-context.md` with:
- New business rules discovered during ticket work
- Common ticket patterns (e.g., "data doesn't match" → BFF transformation layer)
- Domain concept clarifications that came from PM/reviewer feedback

Format:
```markdown
### [Domain Area]: [What was learned]
[The business rule or domain knowledge]
_Learned from: PROJ-XXXX_
```

Add to the appropriate section (your product's feature areas, Key Business Rules, Common Ticket Patterns, etc.).

## 4. Present to User for Review

**DO NOT write changes automatically.** Present:

1. **Lessons extracted** — summarize what was found across all tickets
2. **Proposed additions to `codebase-patterns.md`** — show the exact entries
3. **Proposed additions to `testing-patterns.md`** (if any)
4. **Patterns to retire** — from Section 2.5, the deletion candidates with one-line justifications
5. **Add/retire ratio for this run** — e.g., "+8 / -2 (4:1)" so the user can see the file isn't growing monotonically
6. **Ticket state files to mark `learned`** — list which ticket files will be marked (never deleted)

Ask the user:
- "Apply these updates?" (edit the pattern files — additions AND retirements)
- "Edit first?" (let user modify before applying)
- "Apply additions only, skip retirements?" (conservative path)
- "Skip?" (don't update, just show the analysis)

## 5. Apply Updates

If user approves:

1. **Update pattern files** — append new entries AND apply approved retirements to `codebase-patterns.md` and/or `testing-patterns.md`
   - If the file doesn't exist, create it with a header explaining its purpose
   - Add a `## Lessons Learned` section (or append to existing one)
   - For each retirement approved in Section 2.5: delete the entry from the file AND remove its line from the `## Index`. Do not leave a `<!-- removed -->` comment — the git history is the audit trail.
   - Update the run-summary line at the top of the file (or create one): `<!-- last-run: YYYY-MM-DD: +N -M -->` so the add/retire ratio is visible at a glance.

   **Always update the file's last-updated marker** so `/clarify` and `/refactor` can detect freshness. At the very top of each pattern file (line 1-2), insert or update:
   ```markdown
   <!-- last-updated: YYYY-MM-DD -->
   ```
   Use today's date. If a marker already exists, replace its date. This is the contract: `/clarify` warns when the marker is older than 45 days; `/refactor` uses it to decide if re-scanning is worth it.

   **Maintain a `## Index` section** (create if missing, right after the last-updated marker). For each new pattern appended, add a one-line entry to the index:
   ```markdown
   ## Index
   - [MUI: DatePicker requires LocalizationProvider](#mui-datepicker-requires-localizationprovider) — Source: [[PROJ-5580]], [[PROJ-5501]]
   - [BFF: snake_case vs camelCase attribute mismatch](#bff-snake_case-vs-camelcase) — Source: [[PROJ-5901]]
   ```
   Downstream commands that need a fast scan read the Index, not the full file.

2. **Finalize each ticket — integrity gate → Closeout → mark learned:**

   **(a) Integrity gate (never mark a mid-flight ticket `learned`).** Before flipping status, assert the record is whole: the Implementation Progress table has NO rows in a non-terminal state (anything other than `DONE`/✅ — so unrecognized in-flight tokens like `WIP`/`BLOCKED`/`TODO` block too, not just `IN_PROGRESS`/`PENDING`), AND — for **Standard/Complex** tickets only — the Retrospective is non-empty (Trivial/Dependabot tickets legitimately have none per §1.5's tier gate; don't demand one). If a required check fails, route through §1.5 (backfill the retro; confirm/complete the phase table). If it genuinely can't be completed, leave the ticket at its current status and report it skipped — do NOT stamp `learned` on a frozen-mid-flight doc. (PROJ-6045 reached `learned` with an `IN_PROGRESS` phase table — the phase-table check catches that regardless of tier.)

   **(b) Write the Closeout (own-ticket Outcome + Health).** Create a `## Closeout` section (just above `## Obsidian Links`) if missing, and refresh the region between `<!-- AUTO:CLOSEOUT START -->` and `<!-- AUTO:CLOSEOUT END -->` — everything outside the markers, including the human `## Retrospective`, is NEVER touched. Populate it with the ticket's Outcome (status timeline, `qa_bounces`, cycle time) + Health band, computed per **[[ticket-outcome-spec.md]]**. If `/ci-check` already snapshotted an `outcome:` frontmatter block at merge, **seed `qa_bounces`/`timeline`/`jira_status` from it** (freshest, and survives a skipped retro) and **compute cycle time + story points yourself if absent** — the snapshot intentionally carries only the changelog-derived fields (see the `outcome:` contract in [[ticket-outcome-spec.md]]). Own tickets are FIRSTHAND — state cause directly; no "⚠ inferred" hedge (that's teammate dossiers only). Example:
   ```markdown
   ## Closeout
   <!-- AUTO:CLOSEOUT START -->
   - Outcome: To Do → In Progress → Code Review → QA → Code Review → QA → Done  (entered QA 2× → 1 bounce) · cycle 4.2d · 3 pts
   - Health: 🟠 watch (score 3): +3 (1 QA bounce). The QA round was a copy fix, not a logic defect.
   <!-- AUTO:CLOSEOUT END -->
   ```

   **(c) Mark learned** — update frontmatter:
   ```yaml
   status: learned
   learned_date: YYYY-MM-DDTHH:MM:SSZ
   ```
   This prevents `/learn` from re-processing the same tickets.

   **Also ensure the `tags:` block is present and accurate.** If the ticket doesn't yet have a `tags:` block, or has `tag_confidence: low`:
   - Re-run the classification using the same heuristics as `scripts/tag-tickets.sh` (see that script for axis rules)
   - For anything still ambiguous after heuristics, use the current conversation's understanding of the ticket to pick the axes
   - Bump `tag_confidence: high` and set `tags_verified: true` since you just reviewed the retrospective
   - Write the tags block back into the state-file frontmatter

   The `PostToolUse` hook will re-upsert the index entry automatically on save, so `/clarify` immediately sees the improved tags on the next query.

   Also add (or update) an **Obsidian Links** section at the end of the ticket state file:
   ```markdown
   ## Obsidian Links
   - Patterns updated: [[codebase-patterns]] and/or [[testing-patterns]]
   - Learned date: YYYY-MM-DD
   ```
   Only include whichever pattern files were actually updated for that ticket. If the section already exists, merge new links rather than duplicating.

3. **Mark processed** — set `status: learned` on each ticket file so it's skipped next time.
   - State files are **never deleted** — they stay on disk permanently for retro, /status, and prior-art lookup.
   - `status: learned` is the terminal marker; no `rm`, ever.

## 5.5 Connect Tickets in Obsidian

After processing all tickets, strengthen the knowledge graph:

1. **Cross-link related tickets** — If multiple tickets share the same topic (e.g., `[[playbooks-v2]]`), add `[[PROJ-YYYY]]` to each other's `## Obsidian Links → Related` section (if not already there).

2. **Update topic hub pages** — Check if a topic hub exists at `$WORKSPACE_ROOT/specs/{topic}.md` (e.g., `specs/playbooks-v2.md`). If it does:
   - Add any new tickets to the `## Tickets` section
   - Add a note about the new patterns learned: "Patterns added on YYYY-MM-DD from PROJ-XXXX, PROJ-YYYY"
   
   If no topic hub exists but 3+ tickets share a topic, suggest creating one:
   > "3 tickets share the topic 'buy-credits'. Want me to create a topic hub at specs/buy-credits.md?"

3. **Cross-repo connections** — If tickets from different repos worked on the same feature (e.g., api-bff + addin-fe both touched the same feature area), note this in both repos' pattern files as a cross-repo dependency.

## 5.6 System Retrospective — Command Improvement Proposals

**Goal:** Detect signals that a command underperformed and write concrete improvement proposals. Keep this fast — scan for obvious signals, write proposals, move on.

### Scan ticket state files for signals

For each processed ticket, check for:

| Signal | Detection | Proposal Type |
|--------|-----------|---------------|
| User overrode classification | State file has original tier ≠ what was actually needed (e.g., classified Bugfix but needed Complex investigation) | /ticket classification fix |
| Same command ran 3+ times | Event log shows repeated `/verify`, `/test`, or `/project-debug` entries for one ticket | That command needs improvement |
| Long gaps in event log | >30 min between entries with no "Hit issue" explanation | Missing guidance or Claude was stuck |
| Ticket re-opened after delivery | State file went from `delivered` back to `implementing` | /verify missed something |
| Contract smoke test found ❌ | Contract report has mismatches | /ticket should warn about API boundaries earlier |
| Confidence was LOW on delivered ticket | Verification was superficial for the ticket complexity | /verify depth didn't match ticket needs |
| Event log "Hit issue:" entries | Problems encountered during implementation | Pattern may be missing from codebase-patterns.md |

### Scan conversation for signals (always-on — auto-detected)

Whenever substantial conversation context exists (not gated on any flag — see §0.5):

| Signal | Detection | Proposal Type |
|--------|-----------|---------------|
| User manually did something a command handles | User ran curl, manual git operations, manual test generation | Command gap or wasn't triggered |
| User corrected Claude's approach | "actually that's wrong", "no, do X instead", explicit corrections | Investigation or pattern gap |
| User pasted screenshots to prove breakage | Images shared to show bugs | /verify visual check gap |
| User ran git commands /pr should handle | Manual branch creation, manual commit description drafting | /pr workflow gap |

### Triage each signal at capture time (decide its FORM before writing anything)

A proposal is always a **modification to an existing command — never a new command.** New-command ideas historically die unused (`/pre-flight`, `/security`, `/test`, `/to-qa` were all deleted or folded); if a signal genuinely seems to need a new command, ask the user explicitly instead of filing.

Every detected signal gets exactly ONE of four forms, decided **now** — not 21 days later by the aging gate. This is the capture-time half of the actuator (§0.3 LAND-NOW is the queue-side half):

1. **APPLY-NOW** — the fix is mechanical (a concrete grep / guard / step edit), ≤15 changed lines, ONE target command file. Draft the exact diff and include it in the §4 approval batch alongside pattern updates. On approval, edit the command file in this run, and append a one-line ledger entry to `command-proposals.md` already marked `**Status:** ADDRESSED YYYY-MM-DD — <file>§<section> (landed at capture)`. The queue is skipped entirely; the ledger keeps the audit trail.
2. **COMPILE-TO-CHECK** — the lesson is mechanically checkable in *code* (a grep, a set-diff, a path-pair rule — e.g. "every GAS handler registered on globalThis must appear in build-server.mjs GLOBAL_FUNCTIONS"). **Prose entries demonstrably do not prevent recurrence** (that exact bug recurred twice in 7 days with a pattern entry on disk). Express it as an executable check — a `/verify` §2.6 battery line (tier/path-scoped so it only fires where relevant), a repo hook, or a lint rule — and land it via APPLY-NOW. The pattern-file entry then *cites* the check instead of being the only carrier of the rule.
3. **BATCH-ASSIGN** — design-shaped (new flow, schema, or multi-file change). File it as an OPEN proposal using the base shape below, with a mandatory `**Target:**` line. It gets landed in a **per-command batch session** (release-cadence work, e.g. alongside `/bootstrap --bump`): all OPEN proposals sharing a Target are landed together in one edit pass — one file edit historically closes 2–4 incident-shaped proposals.
4. **DROP** — speculative, single-occurrence, no concrete diff expressible. Don't file it. If the signal recurs, the next occurrence IS the filing trigger (and arrives with `**Occurrences:** 2` evidence built in).

### Write proposals (BATCH-ASSIGN form)

Append to `$WORKSPACE_ROOT/.claude/command-proposals.md` (create if it doesn't exist).

Each proposal carries an explicit lifecycle status so the file doesn't accumulate into shelfware. The base shape:

```markdown
### [YYYY-MM-DD] /command — [Short description]
**Target:** <command>.md §<section-to-modify>
**Signal:** [What was detected]
**Context:** PROJ-XXXX or session description
**What happened:** [Specific details]
**Suggestion:** [Concrete modification — the closer to a ready-to-apply diff, the cheaper it lands]
**Impact:** High / Medium / Low — [Why]
**Occurrences:** 1
**Status:** OPEN
```

When a proposal is later implemented, replace `**Status:** OPEN` with `**Status:** ADDRESSED YYYY-MM-DD — <command-file>§<section>` and a one-line note on how it landed. When a proposal is rendered obsolete (the underlying command was deleted, or the issue has been re-framed), replace with `**Status:** STALE YYYY-MM-DD — <reason>`. Do not delete old proposals; the history is the audit trail.

### Dedupe before appending

Dedupe key = **`(target command, failure-class)` — NOT the signal's prose.** Two proposals about "/clarify greps a stale branch" are ONE proposal even when they cite different tickets in different wording — the old text-similarity rule let that exact pair get filed the same day. Scan for an existing entry (**OPEN or STALE**) with the same Target and the same failure class. Use `grep -nE "^### \[.*\] /command — |\*\*Target:\*\*|\*\*Signal:\*\*" .claude/command-proposals.md`, then judge failure-class match on root cause:

- **Same target + same failure class:** do NOT append. Update the existing entry's `**Last seen:** YYYY-MM-DD` line (add it if absent), increment `**Occurrences:**` (add as `2` if absent), and append a one-line bullet under it citing the new context. **If the entry was STALE, flip it back to OPEN** — recurrence revives killed proposals; that's what makes §0.3's recurrence-KILL safe.
- **Same target, different failure class:** append as a new proposal, and cross-link in a `**Related:**` line.

This prevents the same "/pr should check base branch" idea from being filed three different ways (it was filed seven).

### Rules
- **Triage first (above) is mandatory** — APPLY-NOW and COMPILE-TO-CHECK signals must NOT be filed as OPEN proposals "to do later"; filing a mechanical fix into the queue is the failure mode this whole section exists to prevent
- Run the dedupe scan before any append; bumping an existing entry is always preferred over appending
- Max 5 NEW proposals per /learn run — prioritize by impact (bumps and APPLY-NOW ledger entries don't count toward the cap)
- Every proposal must carry a `**Target:**` naming an EXISTING command file + section, and describe a SPECIFIC modification — never "make X better", never a new command
- Don't propose changes that contradict existing command logic without noting the conflict
- Command files may be modified ONLY via APPLY-NOW (here) or LAND-NOW (§0.3), and ONLY after the user approves the shown diff — never silently
- After any APPLY-NOW / LAND-NOW edit, refresh the edited file's line in workflow-version.md's Hash Ledger (`shasum -a 256 <file> | cut -c1-8`) — otherwise the ledger silently drifts until the next /bootstrap --bump
- **WIP cap: if OPEN count ≥ 20, new BATCH-ASSIGN entries are one-in-one-out** — the run must KILL or LAND an existing OPEN proposal (via §0.3 verdicts) before appending. Above the cap, capture pressure becomes landing pressure instead of queue growth.
- Every new proposal must include `**Status:** OPEN` — a missing status line isn't fatal (§0.3 Step A treats statusless blocks as aged-OPEN and sweeps them) but it delays triage by up to 21 days, so always write it

### Proposal reconciliation → moved to the §0.3 Proposal-Aging Gate

Reconciliation now runs **up-front and unconditionally** in §0.3 (age-derived, every write-capable invocation), not as a conditional pass here. The old "every 5th run / >50 proposals" trigger was dead — there is no run counter, and it only looked at `Status: OPEN` (the youngest cohort), so it never fired and `command-proposals.md` accreted to 94 blocks with 0 ever marked STALE. §0.3 fixes that by sweeping aged OPEN **and** statusless blocks at the top of the run. This section (§5.6) owns the **capture side**: triage (APPLY-NOW / COMPILE-TO-CHECK / BATCH-ASSIGN / DROP) → dedupe → append only what's genuinely design-shaped.

## 5.6.5 Pattern ROI (is the learning actually working?)

`/learn` captures well; this section is its honest attempt to show that the capture *pays off*. Surface the result as a one-line bullet in the §6 Summary.

**Honesty constraint (do NOT violate):** per-pattern / per-proposal ROI is **NOT computable** today. Every metric in every snapshot is keyed by **repo or workspace** — there is no command, proposal-id, or topic dimension in `audit_metrics.py` or its output. You CANNOT say "the visibility-pair pattern cut CSS rework 40%." Claiming a single lesson moved a repo-level number is fabricating a join key that doesn't exist. Build only what the data supports:

**Tier 1 — Process-ROI (precise, from `command-proposals.md` alone — this is the REAL loop KPI):**
- **Landing rate** over the trailing window = `ADDRESSED / (ADDRESSED + STALE + aged-OPEN incl. NO-STATUS, per §0.3 Step A)`. The denominator MUST include the statusless cohort the gate drains, or the KPI is inflated. This is the "is the loop closing" number; the historical value was ~25% (and 0 STALE). After §0.3, it should climb.
- **Add:retire ratio** for this run (already tracked at §3/§4, target ≥ 1 retirement per 5 additions). A monotonically-growing `codebase-patterns.md` means learning isn't being pruned.
- These two need no snapshot and are not confounded — lead the ROI line with them.

**Tier 2 (repo-level deltas) and Tier B (baseline-at-add stamps) were removed in 0.5.2** — on this workspace every repo's rework n<5 permanently suppressed Tier-2, and Tier-B stamps were context nobody read. Tier-1 is the only live ROI number; per-entry ROI remains non-computable without a topic dimension in audit_metrics.py (a separate investment, not /learn's job).

## 6. Summary

Display:
- How many tickets were processed (grouped by repo)
- How many new patterns were added per repo
- Which pattern files were updated
- How many ticket cross-links were added
- Whether any topic hub pages were created or updated
- **NEW:** How many command proposals were written (and where: `.claude/command-proposals.md`)
- **NEW:** Missed command opportunities (inline list, if any)
- **E2E suite health (§2.6, e2e-enabled repos only):** `e2e {repo}: skip-rate {old}→{new}, failed {old}→{new}` — omit the line entirely for non-e2e repos. Flag explicitly when skip-rate climbs while failures drop (false-green drift being skipped, not fixed). If drift-taxonomy lessons couldn't land because the canonical testing-patterns section doesn't exist yet, say so here.
- **Aging gate (§0.3):** `aging: {applied} applied now, {recorded} recorded as landed, {killed} killed, {deferred} deferred ({at_cap} hit defer-cap), {carried} carried over`
- **Capture triage (§5.6):** `capture: {applied} applied now, {compiled} compiled to checks, {filed} filed to batch, {dropped} dropped, {bumped} occurrence bumps`
- **Pattern ROI (§5.6.5):** lead with Tier-1 process-ROI (`landing rate {X}% this window` + `add:retire {A}:{R}`); append Tier-2 repo-level directional deltas only where n ≥ 5, explicitly labeled `directional, not causal`. If neither is meaningful this run, print `ROI: process landing rate {X}% (loop KPI); repo-level deltas below noise floor`.
- **UI-iteration KPI (§2.7, UI repos only):** per active `(surface, correction-class)`, `ui-fidelity {repo}: {surface}/{class} rounds {old}→{new} (n={N})` — the per-class, causally-readable proof the UI meta-learning works (down = improving). Flag flat/climbing classes as meta-lessons that aren't landing, and note `{open-failures}` still-not-right per class. Omit entirely for repos with no captures. This is the one number with a real per-topic join key, unlike the repo-level metrics above.
- Reminder: "These patterns will be automatically loaded by /ticket, /test, /verify, and other commands."
- If proposals were written: "Review command proposals at `.claude/command-proposals.md` when you have time."

</process>

<examples>

```
/learn
→ Scans ALL repos for delivered tickets
→ Finds: addin-fe (3 tickets), api-bff (1 ticket)
→ [[PROJ-5835]] has empty retrospective → asks user: "What went well? What went wrong?"
→ User fills in: "Native inputs slipped through review — need to check codebase-patterns"
→ Clusters lessons: "MUI DatePicker needs LocalizationProvider" appeared in 2 addin-fe tickets
→ Proposes adding to addin-fe/codebase-patterns.md:
  "### MUI: DatePicker requires LocalizationProvider wrapper
   <!-- Learned from [[PROJ-5580]], [[PROJ-5501]] -->
   _Source: [[PROJ-5580]], [[PROJ-5501]]_"
→ Cross-links [[PROJ-5835]] ↔ [[PROJ-5873]] (both playbooks-v2)
→ Updates specs/playbooks-v2.md with new ticket references
→ User approves → files updated, tickets marked as learned

/learn addin-fe
→ Same flow but limited to addin-fe tickets only

/learn --session   (optional hint — conversation-only; plain /learn already mines the conversation too)
→ Skips the delivered-ticket scan, learns from the current conversation only
→ Asks: "What patterns or gotchas did you discover in this session?"
→ User: "Playwright can't trigger MUI Autocomplete freeSolo chip creation"
→ Asks: "Any codebase surprises or undocumented behavior?"
→ User: "Position V2 API returns null for conceptDetection, ifFoundAction, ifMissingAction"
→ Asks: "Any testing insights?"
→ User: "Use Playwright MCP --extension mode with auth token for authenticated testing"
→ Asks: "Which repo(s)?" → detects addin-fe from CWD
→ Proposes entries for codebase-patterns.md and testing-patterns.md
→ User approves → pattern files updated
→ Summary: "Added 2 codebase patterns and 1 testing pattern to addin-fe."

/learn --session api-bff   (optional hint — skips ticket scan; plain /learn api-bff already learns from the conversation too)
→ Same as above but targets api-bff specifically
```

</examples>

<success_criteria>
- [ ] Target repo detected
- [ ] **§0.3 aging gate ran first** — aged proposals (incl. NO-STATUS) swept to LAND/LAND-NOW/DEFER/KILL; defer-cap (2) enforced; carry-over reported if >15
- [ ] **Command-file edits (LAND-NOW / APPLY-NOW) applied only after the user approved the shown diff**; each landing recorded in command-proposals.md
- [ ] Sources auto-detected (not flag-gated): delivered tickets AND/OR current conversation, whichever had signal
- [ ] Delivered ticket files (if any) found, read, retrospectives analyzed
- [ ] Conversation learning (whenever substantial context existed): questions offered, answers tagged `session YYYY-MM-DD`
- [ ] Lessons clustered by category (pitfalls, patterns, undocumented, precedents)
- [ ] **E2E drift (§2.6):** gated on the repo being e2e-enabled (silent skip otherwise); on an e2e-fix ticket each fix classified into the drift taxonomy and appended under the canonical testing-patterns section (or deferred + reported if that section doesn't exist yet); `spec_dir` read from the profile, never hardcoded
- [ ] **E2E suite health (§2.6):** skip-rate + failed-count stamped for e2e-enabled repos and the run-over-run delta surfaced in the summary; `sideload_only` suites counted statically, not run
- [ ] No duplicate entries proposed (checked against existing patterns)
- [ ] Proposed updates shown to user BEFORE writing
- [ ] Pattern files updated only after user approval
- [ ] **Ticket mode:** Processed tickets marked as `learned` (not re-processed next time)
- [ ] **Integrity gate:** no ticket marked `learned` with a mid-flight phase table (any tier); Standard/Complex also require a non-empty Retrospective — failures routed through §1.5 or reported skipped
- [ ] **Closeout:** each learned own-ticket has an `AUTO:CLOSEOUT` region (Outcome + Health per [[ticket-outcome-spec.md]]); the human `## Retrospective` is preserved untouched
- [ ] **Reflection tier-gated:** Trivial/Dependabot tickets skip §1.5; Standard/Complex tickets + substantive conversation sessions run it
- [ ] **Collaboration reflection:** for non-trivial work, the "why did understanding intent take longer?" question is answered from evidence (drafted, not interrogated), and each confirmed friction is converted to a proposed `feedback_*` memory / command-proposal (saved only on approval)
- [ ] **System retro:** Ticket state files and conversation scanned for command underperformance signals
- [ ] **System retro:** Every signal triaged at capture (APPLY-NOW / COMPILE-TO-CHECK / BATCH-ASSIGN / DROP); only design-shaped ones filed as OPEN (max 5, each with **Target:**); WIP cap (20) honored
- [ ] **Missed commands:** Conversation scanned for activities that map to unused commands (if enough context)
- [ ] **Missed commands:** Recurring misses promoted to proposals
- [ ] Summary of changes displayed (including proposal count and missed commands)
- [ ] **UI-iteration synthesis (§2.7, UI repos only):** iteration captures collected into `ui-fidelity-ledger.md`; clusters ≥2 tickets (or any 4+) synthesized into surface-keyed `AUTO:META-LESSONS` with provenance (shown for approval, never auto-written); per-class KPI computed (`rounds=unrecorded` excluded, `99` excluded from mean) and the delta surfaced in §6

## Related Commands
- Source: /ticket (delivered tickets) AND the current conversation — both auto-detected in one pass, no flag needed
- Updates: codebase-patterns.md | testing-patterns.md | .claude/command-proposals.md
- Pipeline: /ticket → /verify → /pr → /learn
- Closes the loop: §0.3 aging gate forces land/defer/kill on aged proposals; §5.6.5 reports process-ROI
- Review proposals: read `.claude/command-proposals.md` and decide which to implement
</success_criteria>
