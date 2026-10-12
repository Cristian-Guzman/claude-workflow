---
version: 0.7.0
last-updated: 2026-10-11
maintainer: your-name@your-org.com
---

# Claude Code Workflow — Version Log

This file tracks the version of the slash-command workflow living in `$WORKSPACE_ROOT/.claude/commands/`. Every command's frontmatter should carry the same `version:` value as the current version below. `/bootstrap` reads this file, writes changelog entries, and bumps versions across commands when the workflow changes.

## Versioning rules

- **MAJOR (x.0.0)** — declares the workflow stable / repo-agnostic. Bump only when you're confident the command surface is complete.
- **MINOR (0.x.0)** — adding, deleting, merging, or significantly reshaping commands. Examples: new `/project-context` command, merging `/related` into `/clarify`, deleting `/session`.
- **PATCH (0.0.x)** — internal refinements (bug fixes, better prompts, added checks) to existing commands that don't change how you call them.

## How to bump

Run `/bootstrap --bump <minor|patch>` (after Phase A of the April 2026 refactor). It:
1. Updates the `version:` and `last-updated:` fields above.
2. Appends a changelog entry below.
3. Propagates the new version into every command's frontmatter.
4. Flags any command whose checksum drifted from the last recorded hash — so you can write accurate changelog notes.

## Changelog

### 0.7.0 — 2026-10-11
**Theme:** the return path — learnings from confidential projects flow back to the generic workflow without carrying provenance.

- **`/upstream` command added** — the counterpart of `/learn`. Harvests a window (default: since the last bundle, else 30 days) of GENERIC learnings out of a company workspace: local edits to core commands (diffed against the install baseline), `ADDRESSED`/recurring proposals from `command-proposals.md`, `AUTO:PROCESS-LESSONS`, and `feedback_*` memories. Each candidate is triaged CORE-PATCH / PROPOSAL / LESSON / TEMPLATE / DROP by a literal noun-deletion test. Writes `.claude/upstream/<harvest-id>--<alias>/` (`CONTRIBUTION.md` + `patches/` + `bundle.json`) and stops for review.
- **Two repos, two directions.** Harvest mode publishes only as an issue to a PRIVATE `inbox_repo` (visibility verified via `gh repo view`), gated on `publish_allowed` and an in-session confirmation; it never runs `git commit`. `--intake <dir|inbox>` runs on a personal machine only (refused when `env` classifies the machine as company), merges all bundles into one `harvest/YYYY-MM` branch, one squashed commit, one PR. Harvest ids are `YYYY-MM-<letter>`; the project alias names a local folder and appears in nothing that leaves — `check` treats it as a leak.
- **Scoped git identity for the intake commit** — `upstream.py identity save|set|restore|show` records the clone's LOCAL `user.name`/`user.email`/`commit.gpgsign`/`user.signingkey`, sets `personal_identity` with signing off (or a personal key), and restores the saved values on every exit path. Global git config is never touched.
- **`scripts/upstream.py`** — deterministic, stdlib-only: `drift`, `sanitize`, `check` (denylist + alias + always-on secrets patterns: cloud keys, GitHub/Slack tokens, private keys, JWTs, `api_key=` assignments; `--generic` for the intake side), `env` (MDM enrollment, global git email domain, GitHub Enterprise hosts → company/personal), `identity`, `log` (append-only `HARVEST-LOG.md`: what left, which denylist hash, check result, destination). Placeholder denylist/domains/prefixes are an error, not a pass.
- **`install.sh`** — records `.claude/.upstream-base/` + `.claude/.upstream-manifest.json` on every full install; seeds `.claude/upstream.json`; new local-state ignore lines. Re-run on existing installs to get a baseline.
- Inventory: `bootstrap.md` canonical table, both READMEs (22 commands). Frontmatter propagated: every command carries `version: 0.7.0`.

### 0.6.0 — 2026-07-31
**Theme:** generic kernel — the system works per-project with minimal context — plus the SDET lane.

**Generic kernel (design principle: config-driven topology + clean low-context degradation):**
- **`guard-base-branch.sh` rearchitected** — `WORKSPACE_ROOT` resolves via `$CLAUDE_PROJECT_DIR` (no silent `$HOME/workspace` fallback that disabled the guard); protected base branches derived from repo-profiles at runtime (nothing hardcoded); `WORKFLOW_LAYOUT=single-repo` first-class mode (root = product repo: commits allowed, base-branch protection kept); honors leading `cd <path> &&` when judging git commands (live false-positive fixed). Functionally tested: 9 guard cases + full virgin-project install.
- **`repo-profiles/_schema.yaml` is the single home for tracker config** — `tracker_system` (jira|github|linear|none) + numeric `jira_transition_*` ids + `default_feature_area` + `ui_surface`/`visual_qa_notes`. README, `pr.md`, `bootstrap.md` §4.5 all point here now (previously three contradicting homes).
- **Zero hardcoded repo topology** — `tag-tickets.sh` maps repo→layer from the profile `type:` field; `audit_metrics.py` drops its repo-name fallback; ui-fidelity agent resolves surfaces profile-first → auto-detect → ask (hardcoded registry demoted to example).
- **`install.sh` completes the low-context contract** — seeds a minimal `CLAUDE.md` skeleton (new `templates/repo/CLAUDE.template.md`), creates ALL runtime dirs the hooks/gitignore reference, initializes `state/index.json`, checklist covers single-repo env + no-tracker lane. Verified on a virgin single-repo project (no Jira, no CLAUDE.md): installs clean, guard works, re-run preserves user-owned files.
- **`bootstrap.md` canonical inventory reconciled with the shipped set** — archived `/do` `/queue` `/retro` `/docs` `/e2e` rows removed (with an explicit drift rule), `/test-plan` added, all 7 agents listed with gates, "two installers" section defines install.sh (copies) vs /bootstrap (adapts) with single-file mode as explicit fallback.
- Housekeeping: `test-plan.md` placeholder sanitized (`PROJ-XXXX`), dead `session-capture.js` shim deleted with its install/README references, README command count fixed (21).

**SDET lane (carried from the unreleased 0.5.2 entry):**
- **`/test-plan` command added** — turns a ticket's ACs into an adversarial, level-classified coverage matrix: cheapest honest test level per AC, the unstated edges, an existing-coverage check, and a **surface-testability step** that emits a minimal manual-QA remainder for surfaces that can't run locally (add-ins, mobile). Read-only on source; writes `.claude/tickets/PROJ-XXXX-test-plan.md`. First proven on a GDocs add-in ticket (20 ACs).
- **Framed as a new lane, not a sixth-pipeline addition** — consistent with the 0.5.0 fold-don't-add principle. `/test-plan → /automate → /verify-coverage` is a distinct SDET pipeline (goal = coverage), reusing the state-file + repo-detection + `/learn` machinery. `/automate` and `/verify-coverage` are planned.
- `/verify` evidence-backed 0-100% confidence score (`verify-score.py` + design doc).
- Frontmatter propagation done with this bump: every command carries `version: 0.6.0`.

### 0.5.2 — 2026-07-04
**Theme:** close the loop on the /learn investigation — drift detection, dead-weight cut, planning-time read-path.

- **`state-index-upsert.sh` status-vocabulary guard** — non-schema statuses (the `stashed-wip` / `"FIXED (…)"` class that made tickets invisible to /learn) are still indexed but now logged to `state/schema-drift.log` with date + file. Syntax-checked + smoke-tested (schema-valid file logs nothing).
- **`learn.md` dead-weight cut: 1008 → 802 lines (−206).** §0.4 Audit-Only Mode removed (flag + §0.3 mode-guard reference too); §5.6.5 Tier-2/Tier-B removed (permanently suppressed on this workspace — Tier-1 landing-rate + add:retire is the only live ROI number); §5.7 Missed Command Opportunities removed (contradicted the 0.5.0 fold-don't-add core-pipeline principle).
- **`clarify.md` §1.5b process-ledger read-path** — Prior Art now surfaces up to 3 matching `AUTO:PROCESS-LESSONS` from `{REPO}/.claude/process-ledger.md` at planning time; completes the 0.5.1 capture→distill→apply loop (was listed as a 0.5.1 follow-up).
- Still owed: proposal burn-down (51 OPEN, 7 forced decisions pending), addin-fe patterns reorg, plan-checker gate, frontmatter propagation.

### 0.5.1 — 2026-07-03
**Theme:** /learn reoriented from pattern-appender to process distiller. User diagnosis: capture died when chats closed without /learn, and the output had drifted into "adding code patterns without much sense" instead of "how we do things in this project."

- **Capture moved to where work happens:** `/pr` §8 now writes a mechanical `## Process Summary` block (sessions, phases, fix_iterations, debug links, commits, days-to-PR — all derived from the Event Log + git, `unrecorded` when underivable, never estimated) into the state file at PR time. Closing a chat without /learn no longer loses telemetry.
- **`/verify` §8.5** — non-UI note added: the rounds survey stays UI-only (design rightness isn't machine-readable); non-UI iteration cost comes from the Process Summary mechanically.
- **`/learn` §2.7b Process Synthesis (new, PRIMARY output)** — generalizes §2.7 beyond UI: per-repo `process-ledger.md` with `AUTO:PROCESS-LOG` + clustered `AUTO:PROCESS-LESSONS` ("next time do X first" rules, ≥2-ticket recurrence bar, provenance, per-class KPI = mean fix_iterations/sessions trailing-3 vs prior-3).
- **`/learn` §3 recurrence gate** — pattern entries now require a SECOND occurrence (mirror of §5.6 DROP); first occurrences stay in the ticket state file. Exceptions: mechanically-checkable lessons (→ COMPILE-TO-CHECK) or explicit user ask. Directly attacks the 5,839-line accretion problem.
- Follow-ups (not landed): `/clarify` prior-art read-path for `process-ledger.md`; per-command frontmatter propagation still owed.

### 0.5.0 — 2026-07-02
**Theme:** external-workflow audit → prune + mechanical enforcement. Triggered by a 26-agent audit comparing this system against 10 external workflows (GSD, a corporate workflow export, BMAD, Agent OS, CCPM, SuperClaude/claude-flow, spec-kit, Anthropic official guidance, superpowers/compounding-engineering, HumanLayer ACE-FCA). Verdict: more mature than all 10 for this user's niche; specialization 6.5/10 — "well-specialized at the core, over-generalized at the edges." Raw audit data: session scratchpad `audit-full.json`.

**PRUNE (first real execution of the 0.4.0 machinery):**
- `/do`, `/retro`, `/queue`, `/docs`, `/e2e` archived to `.claude/_archived-commands/` — zero usage evidence (state-index kind counts, no artifacts, owner memory disowns /do and /retro). New `capability-manifest.md` records each decision + reversal path. README.md + routing.md references cleaned; `audit_metrics.py` do_routing metric goes null harmlessly (guarded at line 376/460).
- `/demo-summary` was archived then un-archived the same day on user correction — created ~1 week earlier and actively wanted; "no artifacts" meant NEW, not dead. Manifest lesson: age-gate usage evidence.
- `/e2e` folded into `ticket.md` §5.1a (E2E coverage during the final Verify phase, headed-local validation rules inline) per the user's core-pipeline vision.
- **Core-pipeline principle (user-stated, canonical in commands/README.md):** `/clarify → /ticket → /verify → /qa → /pr → /learn` are the per-ticket commands, each run ONCE per ticket; bugs route to `/project-debug` or the `/ticket` §5.1b gate. Future capabilities fold into these six — no new commands.
- Command surface: 26 → 21 files (20 commands + README).

**Mechanical enforcement (prose rules → PreToolUse hooks):**
- New `scripts/guard-base-branch.sh` wired as PreToolUse in `settings.local.json` (matchers: Edit|Write|MultiEdit|NotebookEdit and Bash). Blocks: edits inside a product repo sitting on a base branch (feedback_branch_before_edit), `git commit` on a base branch, and commit/push in the workspace-root repo (feedback_no_commit_workflow_files). Exempt: any `.claude/` path, workspace-root *.md, non-git paths. Tested on 3 cases before wiring.

**Command changes:**
- `ticket.md` §5.0 — worktree isolation: when another in-progress ticket exists on the same repo (or foreign working-tree changes are present), branch in `../{repo}-wt/{TICKET_ID}` via `git worktree add` instead of the shared checkout; `worktree:` recorded in state-file frontmatter; `/ci-check` removes it post-merge. Kills the shared-checkout failure classes (PROJ-6504 sibling-commit incident).
- `ci-check.md` — new §3b CI-failure repair loop: red CI → `gh run view --log-failed` tail → cause-known gate → minimal fix behind per-commit confirmation → re-poll; max 2 rounds, then /project-debug (E2E failures reproduce locally first).

**Roadmap (audit findings NOT landed here — next sessions, roughly ranked):**
1. Deepen the `/ticket` §5.1a E2E fold if the inline version proves too thin (the old /e2e spec is in `_archived-commands/` for reference).
2. Fold the Dependabot lifecycle (8 memory files) into `/ticket` as a first-class tier path.
3. Pre-execution plan-checker gate: adversarial blueprint check before `/ticket` phase 1 (AC↔phase coverage, contradiction scan, deferred-scope firewall) — GSD/spec-kit/superpowers all converged here.
4. Deferred consolidations, still owed: verify.md deep-cut, bootstrap.md deep-cut (~40%), 51-OPEN proposal burn-down (cap is 20), addin-fe patterns-file reorg, frontmatter version propagation (NOT done this release either — 0.4.0 precedent). Also: prose mentions of the archived commands linger in memory-lint/bootstrap/clarify/learn/project-context/ticket .md files — cosmetic, sweep at next `--bump`.
5. Skills-format migration (`disable-model-invocation` on side-effect commands, `!`-preprocessing for live Jira/diff injection); phase-boundary compaction artifact; waiver ledger with expiry; verbose-gate output distillation.

### 0.4.0 — 2026-06-30
**Theme:** Adaptive `/bootstrap` + UI meta-learning loop. Two user-driven features.

**Adaptive `/bootstrap` (capability-gated install/prune):**
- The `### Commands` canonical inventory is now a **capability→command matrix**: the Gate column is a capability expression (`ticket_system != none`, `ui_surfaces != none`, `vcs_host != none AND ci == yes`, `memory_system == yes`, `repo_count >= 2`, `team`) evaluated against a new **§3i capability probe** `{vcs_host, ci, ticket_system, wiki, e2e, ui_surfaces[], repo_count, memory_system, team}`. Same inventory → different installed set per project.
- **New PRUNE action (§4 + §8.5):** a command whose gate goes false is **archived to `.claude/_archived-commands/` (never deleted)** with a logged reason — the "se deshaga de comandos" behavior. Core/`always` commands are never pruned; re-runs only act on gates that flipped.
- **New `capability-manifest.md` (§8.6):** persisted per-project record of the capability vector + per-command install/prune decision + reason — auditable, diffable on re-run (the portable "skill-manifest" lesson harvested from the corporate workflow export).
- Table reconciled to the real command set: removed stale `security` (folded into /verify long ago), renamed `debug`→`project-debug` / `resume`→`resume-ticket`, added the previously-untracked `memory-lint`, `demo-summary`, `ui-fidelity` with proper gates (memory-lint only when an auto-memory dir exists; demo-summary only with a team + ticket system).

**UI meta-learning loop (`/verify` + `/learn` + `ui-fidelity` agent):**
- `/verify` §8.5 captures rounds-to-right + correction-class at human confirmation (UI-gated, non-blocking); `/learn` §2.7 synthesizes surface-keyed meta-lessons into per-repo `ui-fidelity-ledger.md`; the `ui-fidelity` agent reads them at Process step 0. KPI = mean rounds per `(surface, correction-class)`, must trend down — the one causally-readable, per-topic metric (repo-level metrics can't segment).

**Bookkeeping:** touched-file versions bumped (bootstrap/verify/learn → 0.4.0, clarify → 0.4.1); hash ledger refreshed for those files. **Full `--bump` version propagation across all 25 command frontmatters is deferred to a dedicated `/bootstrap --bump minor` run** — this entry documents the drift honestly rather than faking a clean propagation. The other earmarked 0.4.0 item (bootstrap regeneration-from-live-files) remains pending.

### 0.3.1 — 2026-06-11
**Theme:** `/learn` gets an actuator. Triggered by a 5-agent investigation (spec forensics, outcome tracing, pipeline economics, consumption audit, red-team) after the user observed the proposal loop wasn't producing useful data. Proposals are, by standing rule, **modifications to existing commands — never new commands**.

**Diagnosis (evidence-backed):** capture was free, landing was forbidden — learn.md's own §5.6 rule said "NEVER modify command files directly." The §0.3 gate could only *record* landings (LAND required pre-existing evidence), so DEFER (one free date stamp) won **74-to-0**; the queue grew **+12/week** to 94 OPEN at a **14% lifetime landing rate**, and **0 of 16 ADDRESSED** were ever landed by /learn itself (all by dedicated release/batch sessions). 8 of the highest-impact OPEN proposals **recurred in production while waiting** (GAS GLOBAL_FUNCTIONS 2× in 7 days despite a pattern entry on disk; visual-fidelity PROJ-6086/6087→6326; CI-tsconfig + test-extension on PROJ-6394). Prose doesn't prevent recurrence: /verify's fixed ~250-line core slice never read the Lessons zone /learn appends to, and subagents don't inherit prose loaded in the parent context. ~23% of the queue was functionally redundant (dedupe keyed on signal text, not root cause).

**/learn (the bulk of the release):**
- **§0.3 gate — effort-symmetric verdicts.** New **LAND-NOW**: applies mechanical ≤15-line single-target-file diffs in-run, behind a shown-diff approval, max 3/run. **Defer cap = 2** (Step A's awk now emits per-block `Reviewed:` counts; at the cap, LAND-NOW-or-KILL is forced). **Recurrence-based KILL**: aged 21d+ with `Occurrences < 2` → STALE — reversible, never a deletion; §5.6 dedupe revives a STALE entry when its signal recurs. Aged set is processed **grouped by target command** (one edit closes several incident-shaped proposals).
- **§5.6 — capture-time triage.** Every signal becomes exactly one of: **APPLY-NOW** (mechanical ≤15 lines → applied at capture, ledger entry written pre-ADDRESSED), **COMPILE-TO-CHECK** (mechanically-checkable lessons become tier/path-scoped /verify battery lines, hooks, or lint rules — not prose), **BATCH-ASSIGN** (design-shaped → filed OPEN with mandatory `**Target:** <command>.md §<section>` + `**Occurrences:**` fields), or **DROP** (single-occurrence speculation — not filed; recurrence is the filing trigger). Dedupe key coarsened to `(Target, failure-class)`. **WIP cap: 20 OPEN, one-in-one-out above it.** The "NEVER modify command files" rule replaced with "only via APPLY-NOW/LAND-NOW behind explicit approval."
- **§3** — pattern entries capped at ≤8 lines (rule + why + source; war stories stay in the ticket state file).
- `verify.md` Step 0 — after Step 2 identifies modified files, a second **targeted** pull resolves the pattern file's in-file `## Index` for surface-matching entries plus the 10 newest Lessons Learned entries. Closes the "fixed core slice never sees what /learn writes" blind spot.
- `command-proposals.md` header rewritten to document the new lifecycle for future agents.

**Bookkeeping:** version propagated to all 23 command frontmatters. Hash ledger regenerated 2026-06-11; 8 files (build, clarify, memory-lint, pr, refactor, review-pr, ticket, verify) had silently drifted since the 2026-05-28 ledger (un-versioned post-0.3.0 edits) — drift documented here, ledger truthful again.

**Known not addressed (deliberate — "rewrite only what's necessary"):** §0.4 audit-only, §5.6.5 ROI, §5.7, §2 taxonomy left intact despite low yield (cut candidates for 0.4.0). The 93-OPEN backlog burn-down happens via per-command batch sessions (the new gate processes 15/run with the defer-cap forcing decisions). Failure-class reorganization of addin-fe's 5,861-line patterns file is its own session (`/refactor --docs` shape). `/bootstrap` regeneration-from-live-files (live system → bootstrap, never the reverse) is the planned 0.4.0 theme.

### 0.3.0 — 2026-05-28
**Theme:** Opus 4.8 audit + tier-aware routing. Triggered by a 10-agent audit (re-scored by 8 agents after fixes) on the day Opus 4.8 launched. A sharper grader dropped the score from a flattering 9 to an evidence-backed 6.2 and surfaced ~30 real defects; this release fixes them and adds the connective tissue the system was missing.

**Routing (the headline):**
- New canonical flowchart `routing.md` — single source of truth mapping ticket signal → tier → exactly what loads. `/do`, `/clarify`, `/ticket` all resolve the SAME tier from the SAME signals (no drift).
- `/clarify` now **classifies at Step 1.2, before loading anything**, and **short-circuits Trivial** (Dependabot/config/copy) to a one-paragraph blueprint — no patterns, no investigator, no prior-art, no Confluence. Heavy loads deferred until after classification. Lands the "don't overstimulate the agent on trivial work" principle ([[feedback_right_size_context_by_tier]]).
- `/do` routes Trivial straight to implement → CI → /pr (no `/clarify` detour); `/ticket` points its tier matrix at `routing.md`.

**Correctness:**
- Lifecycle reconciled everywhere (`planning → in-progress → ready-for-pr → pr-generated → delivered → learned`); the `delivered`-set-by-`/pr` phantom removed from ticket/pr/README/do/learn/state-file-schema. State-file `rm` deletions removed (never-delete rule). `state-file-schema.md` now documents the statuses actually used.
- `contract-verifier` jq rewritten from OpenAPI-3.0 to Swagger-2.0 definition-centric extraction (was silently returning null on every spec); handles both spec shapes + schema-less detection.
- `verifier` + `pr-branch-reviewer` given scoped `tools:` frontmatter (were inheriting Write/Edit). `commit-drafter` `chore(deps)`/`[[brackets]]` fixed. `queue` model → `claude-opus-4-8` (no Sonnet). Hardcoded `main` → base-branch resolution in `qa` + `pr-branch-reviewer`. `do.md` emojis stripped. Dead `/related` refs removed (4 files). `verify` `Agent(`→`Task(`. `ticket` duplicate Classification block removed.

**State index:**
- `*-review.md` logs now index as `kind: review` (terminal, archived, kept for /learn) instead of `kind:ticket/status:unknown` zombies — flushed 19. Added `$WORKSPACE` containment guard (stops foreign-repo `repo:""` leaks). `review` added to the kind enum.

**Metrics (revived from dead):**
- `audit_metrics.py` discovers repos dynamically (8, was 5 hardcoded; skips <1.5KB stubs), filters rule-violation scans to the user's own commits (coauthor 111→2), and accepts nested `metadata.type` frontmatter (cleared false bad-frontmatter flags). `run_audit.sh` hardened against the `getcwd` TCC failure. `/retro` now reads the snapshot `--diff` (new signal F); `/learn` reads pattern_specificity + memory_integrity to target the weakest file.

**/learn — close the loop (the headline self-improvement fix):**
- Grounded in a 6-agent investigation that overturned the framing: the real backlog isn't "28 OPEN" — it's **63 statusless pre-schema proposals** (57 older than 21 days) the old reconciliation never saw, plus a dead trigger ("every 5th run" — no run counter exists; ">50 + OPEN>30d" returns empty since max OPEN age is 17d).
- New **§0.3 Proposal-Aging Gate** runs FIRST, unconditionally, age-derived from the `### [date]` header (treats *missing* Status as aged-OPEN so the 63-block backlog is finally swept). Opus pre-classifies each aged proposal (greps the target command for landing evidence) → one forced LAND/DEFER/KILL table, capped 15/run oldest-first with explicit carry-over. LAND→ADDRESSED, KILL→STALE (the syntax that had 0 instances), DEFER→`**Reviewed:**` snooze. Consolidates and replaces the dead §5.6 trigger. Makes "0 STALE" impossible to fake.
- New **§5.6.5 Pattern ROI** — honest by construction (all snapshot metrics are repo-keyed; per-pattern ROI is NOT computable and the spec refuses to fake it; an adversarial verify pass caught and removed a Tier-B per-entry overpromise). Tier 1 = process-ROI (landing rate + add:retire ratio, from the file alone — the real loop KPI). Tier 2 = repo-level directional deltas (n<5 suppressed, labeled non-causal; on this workspace all rework n<5, so Tier-1 is the only live number). Tier B = a repo baseline-at-add *timestamp* (context only, explicitly NOT the entry's effect).
- `--session` folded into auto-detect (per [[feedback_learn_auto_detects_mode]]) — conversation learning is now always-on; the flag is an optional "conversation-only" hint, never required.

**Hygiene:**
- Deleted `settings.json.bak` (leaked cookies, now session-rotated), `bootstrap.md.bak`, `.DS_Store`, `2026-04-28-post.json` cruft. `billing-service`/`backend-services` profiles corrected (Go commands, real base branches). `context-monitor.js` hook path made absolute.

**Known not addressed:**
- `verify.md` deep-cut (722→~250) and command consolidation (24→~12) deferred — structural, want their own session.
- launchd timer still needs a one-time Full Disk Access grant (remote `/schedule` can't read local repos); pre-push hook covers generation meanwhile.

### 0.2.1 — 2026-05-12
**Theme:** close the proposal feedback loop + first outcome metric. Triggered by a 20-agent audit that found `/learn → command-proposals.md` was leaking effort (25% landing rate, 83% dead at 21d) and metrics measured activity not outcomes.

**Enhancements:**
- `/pr` Step 1.5 — added profile-vs-reality sanity check (greps last 5 merged PRs' `baseRefName`, warns when modal recent base differs from the repo profile's `base_branch`). Lands the 2026-04-18 dead proposal.
- `/pr` Step 6 — split into 6a (discover workflow keywords from `.github/workflows/*.yml`) + 6b (run baseline CI + any uncovered workflow step like `format:check`, `prettier`, `lint`, `typecheck`). Lands the 2026-04-16 GDocs Add-In format:check miss.
- `/pr` Step 8.5 — added assignee email gate before Jira transition; fetches `fields.assignee.emailAddress` via `getJiraIssue` and skips the <CODE_REVIEW_TRANSITION_ID> transition (look up per-project via jira CLI or MCP getTransitionsForJiraIssue) with a logged reason when the assignee isn't the user. Lands the 2026-04-21 [[PROJ-6022]] cross-assignee proposal.
- `/learn` Section 5.6 — proposals now carry an explicit `**Status:** OPEN|ADDRESSED YYYY-MM-DD — <command-file>§<section>|STALE YYYY-MM-DD — <reason>` lifecycle marker. Added a **dedupe-before-append** scan (existing OPEN entry with same command+signal → bump `**Last seen:**` instead of appending duplicate) and a **reconciliation pass** every 5th /learn run (or when proposals exceed 50). Goal: stop the proposals file from accreting unread.
- `command-proposals.md` — three 04-16/04-18/04-21 `/pr` proposals marked `**Status:** ADDRESSED 2026-05-12` with file+section pointers.
- `scripts/audit_metrics.py` — new `ticket_cycle_time()` function: joins `state/index.json` ticket entries (kind=ticket, branch != placeholder) with `gh pr list --state merged --limit 200 --json mergedAt,headRefName` per repo, computes mean/median hours-to-merge over 30d. Wired into snapshot dict, headline, and diff output. First reading 2026-05-12: addin-fe median 316h (~13d), gdocs-addin 13.7h, mail-service 16.4h, overall n=20 mean 145.5h. **This is the dial that answers "are we improving?"**

**Agents:**
- Promoted `verifier` and `pr-branch-reviewer` from addin-fe-only to workspace-level fallbacks at `$WORKSPACE_ROOT/.claude/agents/`. Each carries a "Workspace generic copy" header explaining repo-override precedence and how to translate the inline TypeScript/React commands for non-TS repos. Repo-specific copies at `{REPO_ROOT}/.claude/agents/<name>.md` still take precedence when present.
- `debugger`, `e2e-writer`, `ux-reviewer` left in addin-fe — they encode that repo's design system / debug protocols too tightly to promote without rewriting.

**Hygiene:**
- `playbooks-v2-status.md` deleted (232 lines, 0 consumers, 31 days stale).
- Three stale `project_*.md` memos deleted from auto-memory (sprint_board_2026_03_26, backend_attribute_bug, playbook_v2_kickoff — all 47 days old, point-in-time snapshots that had outlived relevance). `MEMORY.md` index updated to match. `project_word_addin_2tier_epic.md` kept (still active).
- `settings.json` purged: 88 → 75 allow entries. 9 entries containing real session + support-widget cookies removed; 4 malformed entries (a username typo, broken `awk`/`sed`/`Read(//\\/**)`, `__NEW_LINE_` curl fragment) removed. Backup at `settings.json.bak-2026-05-12` pending session-rotation by the user.
- Hash ledger: `resume.md c98cd0a2` (ghost — file doesn't exist) replaced with `resume-ticket.md 77f0826c`. All 23 command hashes recomputed from current file contents.
- Agent ledger updated to reflect 2 promoted fallback agents.

**Known not addressed in this release:**
- `bootstrap.md` is 82KB / 1674 lines, ~40% cuttable per audit (the `<command-specs>` block duplicates spec content already in `commands/*.md`). Deferred — too risky to refactor in the same session as the proposal-loop changes since `/bootstrap` is itself the installer.
- The launchd job at `~/Library/LaunchAgents/com.<user>.claude-audit.plist` is still blocked by macOS TCC (`Operation not permitted` on `~/Documents` since 2026-04-28). Metrics generated manually until Full Disk Access is granted to launchd OR the script is moved out of `~/Documents/`.

### 0.2.0 — 2026-04-28
**Theme:** make the workflow shareable. `/bootstrap` becomes a portable, drop-in single file; deeper specs make generated commands closer to production-ready on first install.

**Additions:**
- `/memory-lint` — audit auto-memory directory for drift (orphan files, broken pointers, schema violations)
- `.claude/command-proposals.md` — promoted to canonical inventory; `/learn` and `/clarify` append here when they detect recurring command-underuse signals
- `--flavor <name>` flag on `/bootstrap` for domain-specific overlays
- `--source <url>` documented as v0.3.0 candidate (publish .claude/ as a git source)
- `.claude/scripts/audit_metrics.py` + `.claude/metrics/` — Sigrid-style deterministic measurement of self-learning quality (pattern specificity, /learn add/retire ratio, /do routing coverage, rule violation counts, stale-file accumulation). One JSON snapshot per run; directory listing IS the trend history. Triggered by per-repo pre-push hooks (`claude-audit-hook v1`) installed by `/bootstrap`; launchd LaunchAgent is an opt-in alternative that needs Full Disk Access on macOS Documents/Desktop/Downloads paths.
- `/do` routing coverage contract — every command in `commands/*.md` (except `do.md` and `README.md`) MUST appear in `/do`'s routing table. Audit script reports `do_routing.coverage_pct`; deviation flags drift.

**Deletions / Merges:**
- `/pre-flight` — merged into `/clarify` Step 0.5 (setup auditor) and `/ticket` Step 0
- `/security` — folded into `/verify` Step 6 (security quick-scan, always-on)
- `/test` — superseded by `/build` (no-ticket implementation) and `/verify`'s tests-for-every-source enforcement

**Enhancements (from this release):**
- `/bootstrap` — full rewrite. Portable across workspaces (no hardcoded user paths; everything derives from `WORKSPACE_ROOT` resolved at runtime). Single canonical inventory table is the source of truth for both fresh-install and upgrade flows. Version-aware upgrade walks `ACTUAL → TARGET` step-by-step. Stack-flavor detection (`frontend-web | backend-api | fullstack-monorepo | cli-tool | library`) drives flavored seed rules, DoD additions, and `/verify` simplify-checklist. Inlined schemas (`state-file-schema.md`, `_schema.yaml`, both index scripts) so bootstrap actually creates them. PostToolUse hook uses `$CLAUDE_PROJECT_DIR`. Tier-gated install (core / recommended / multi-repo / optional). Deeper specs (50–80 lines each) for `/verify`, `/ticket`, `/pr`, `/clarify`, `/learn`, `/review-pr` so generated commands are capable, not stub-shaped.
- `/learn` — `--session` mode formalized in spec (4-prompt pattern + source tagging `_Source: session YYYY-MM-DD_` vs `_Source: ticket:<ID>_`). Always-on conversation-signal scan appends recurring gaps to `command-proposals.md`. **New Section 2.5 "Identify Patterns to Retire"** — five retirement criteria (stale source ticket >90d, superseded by specific entry, code reality changed, contradicted, pure process commentary). Section 4 now requires presenting an add/retire ratio per run; Section 5 applies retirements alongside additions. Goal: keep `codebase-patterns.md` from growing monotonically.
- `/ticket` — state lifecycle reconciled with `/pr` and `/ci-check`. Ticket finishes phase 8 at `ready-for-pr` (not `delivered` — that transition belongs to `/ci-check`). Removed the file-deletion stanza that contradicted `feedback_never_delete_state_files`. Lifecycle is now: `planning → in-progress → ready-for-pr → pr-generated (/pr) → delivered (/ci-check) → learned (/learn)`. Files never deleted.
- `/do` — routing table expanded from 7 → 20 intents. Every command in the inventory now has an explicit trigger phrase; `/do` is no longer a dead end for half the surface. Added coverage contract enforced by `audit_metrics.py`.
- `mark-ci-passed.sh` (addin-fe pre-push hook) — now honors `tool_response.exit_code`, `is_error`, `interrupted`, plus stdout/stderr failure-phrase scan. Previously created the CI-passed marker on every `yarn ci` invocation regardless of outcome, silently allowing pushes after a failed local CI run.
- `/review-pr` — full multi-strategy spec (worktree / diff-only / fetch-ref selected by PR shape). Bimodal confidence (Author × Reviewer, headline = min, gaming guards). Trump/discuss/approve decision tree with gut-check override. Two-output rendering (≤80-line report + ≤15-line PR comment). Review-log feedback loop into `/learn`.

**Drift detected (committed but not authored in this release — requires user one-liner):**
- `/clarify` — content changed since 0.1.1 hash ledger
- `/verify` — content changed since 0.1.1 hash ledger

### 0.1.1 — 2026-04-22
**Refinements (Sessions 1-3 + multi-axis tagging):**

Security + pipeline integrity:
- Removed `skipDangerousModePermissionPrompt: true` from global settings
- Re-narrowed `Read(//<home>/**)` to specific subdirs
- `/ci-check` — added base-branch resolution via repo profile + wrong-base merge block
- Split ticket lifecycle: `/pr` sets `status: pr-generated`, `/ci-check` transitions to `delivered` (no more event-log overwrite)
- New `.claude/state-file-schema.md` — contract for all commands touching ticket state

State registry (v2):
- New `.claude/state/index.json` + `scripts/state-index-upsert.sh` + `scripts/state-index-scan.sh`
- `PostToolUse` hook auto-maintains the index on every state-file write
- `/status` reads from the index (O(1)) instead of scanning 9 repos

Multi-axis tagging:
- Index schema v2 with `tags: {layer, kind, surface, atomic_level, concern[], feature_area[]}` object
- Closed enums per axis in `state/README.md`; `feature_area` list in `repo-profiles/feature-areas.yaml`
- `scripts/tag-tickets.sh` backfilled 26/27 tickets; audit in `state/tag-audit.md`
- `/clarify` — new Step 1.5b: prior-art lookup from index, hard cap 3 tickets, ~105 lines total (75× reduction vs reading 20 full tickets)
- `/clarify` — `--no-prior-art` and `--full-history` overrides
- `/learn` — bumps tags to high-confidence + `tags_verified: true` when marking learned

Architecture consolidation:
- Deleted `addin-fe/.claude/commands/` (12 duplicate repo-level command files)
- `commands/README.md` + `MEMORY.md` — commands live only at workspace root; repos hold patterns/agents/hooks/scripts/state
- `/bootstrap` — forbids creating `.claude/commands/` in sub-repos, surfaces existing ones as drift bugs

Subagents (3 now):
- New `commit-drafter` agent; `/pr` Step 3 prefers it with inline fallback
- `codebase-investigator` classifies components by atomic level
- `jira-context-loader` parallelizes ticket graph fetch

Meta:
- Removed `/init` + `/session` (consolidated into `/learn --session` / built-in)
- Merged `/related` into `/clarify` Step 1.5
- Renamed `/merge` to `/ci-check`
- Base-branch detection moved to `repo-profiles/` YAML; `/pr`, `/verify`, `/ci-check` all read from profile
- Archived 23 `learned` tickets in index (files preserved per user rule)
- addin-fe profile: added `prototype_branches: [proto/word-addin-v2]`, `component_organization: hybrid`

### 0.1.0 — 2026-04-17
Initial versioned workflow. Baseline captured after the April 2026 refactor.

**Deletions:**
- `/session` — redundant with `/learn --session`
- `/related` — merged into `/clarify` as Step 1.5

**Additions (in progress):**
- `/project-context` — cross-repo connection mapping (incremental cache)
- `/status` — scoped cross-repo work dashboard
- `/retro` — sprint-level retro with team signals
- `/pre-flight` — pre-ticket repo hygiene (base branch, pull, clean tree)
- `/ci-check` — post-`/pr` CI watcher + auto `/learn`
- `.claude/agents/` — reusable subagents starting with `codebase-investigator` and `jira-context-loader`
- `.claude/repo-profiles/` — YAML per repo (base branch, CI command, patterns paths)

**Enhancements:**
- `/pr`, `/verify` — auto-detect base branch per repo (some repos use a non-default base branch, e.g. api-bff + web-app use `develop-v2` — recorded in the repo profile)
- `/verify` — enforce tests-for-every-source, base-branch sanity check, read command-proposals
- `/clarify` — load FULL patterns file + freshness check, parallelize 6-way codebase investigation, setup auditor (README/CLAUDE.md/patterns check)
- `/learn` — write `<!-- last-updated -->` marker + maintain `## Index` section in pattern files
- README.md — documents all 22 commands (was 14)

**Security:**
- Removed hardcoded `POSTMAN_API_KEY` from `~/.claude/settings.json`
- Narrowed `Read(//<home>/**)` to specific subdirs

**Workflow patterns captured (2026-04-21):**
- Spec-driven prototype workflow (designer-provided prototypes in addin-fe): `/clarify` now has a Step 2.5 that detects prototype-branch references and surfaces interaction code as reference-only; `repo-profiles/_schema.yaml` has a new `prototype_branches:` list field; `addin-fe.yaml` lists `proto/word-addin-v2`; user memory `feedback_prototype_as_reference.md` enforces the "prototype = reference, not code" rule across sessions
- Atomic-design awareness: `/clarify` Step 1.8 classifies the design reference (prototype / spec / none); Steps 4b, 4b.1, 4b.2 emit atomic-level pattern tables, ticket scope classification (atom-new, molecule-new, organism-new, page-assembly, mixed-layer), and atomic-first execution order. `codebase-investigator` agent classifies found components by atomic level using heuristics or the repo profile. `_schema.yaml` gains `component_organization` and `atomic_levels` fields. `addin-fe.yaml` set to `hybrid`; `web-app.yaml` set to `flat`. `/learn` extends pattern category tags with atomic level (`[Atom]`, `[Molecule]`, …) so future `/clarify` runs surface the right reuse candidates. User memory `feedback_atomic_design.md` enforces atomic thinking across all UI tickets (including those without design input — "abstract as you go")

## Command inventory at this version

Count: **23 commands** at v0.3.1. No commands added or removed since 0.2.0; the inventory table below is unchanged. All 23 per-command frontmatter `version:` fields are now aligned to 0.3.1 and the Hash Ledger was regenerated from current contents (2026-06-11) — header, frontmatter, and ledger are consistent.

| Command | Version | Role |
|---------|---------|------|
| `/do` | 0.3.1 | entry-point router |
| `/clarify` | 0.3.1 | pre-ticket investigation (incl. former /related) |
| `/ticket` | 0.3.1 | start a Jira ticket |
| `/resume` | 0.3.1 | resume interrupted session |
| `/verify` | 0.3.1 | goal-backward AC verification (+ security quick-scan, was `/security`) |
| `/pr` | 0.3.1 | PR deliverables + branch-base detection |
| `/review-comments` | 0.3.1 | triage feedback on YOUR PRs |
| `/review-pr` | 0.3.1 | review someone else's PR |
| `/learn` | 0.3.1 | extract patterns from delivered tickets (+ `--session` mode) |
| `/build` | 0.3.1 | implement without a ticket |
| `/refactor` | 0.3.1 | pattern violation scan + fix |
| `/e2e` | 0.3.1 | Playwright E2E test generation |
| `/project-debug` | 0.3.1 | systematic debug session |
| `/qa` | 0.3.1 | manual QA guide |
| `/screenshot` | 0.3.1 | page screenshot |
| `/docs` | 0.3.1 | Confluence search/create/update |
| `/queue` | 0.3.1 | off-peak automated implementation |
| `/bootstrap` | 0.3.1 | workflow release manager (portable + version-aware upgrades) |
| `/project-context` | 0.3.1 | cross-repo connection map |
| `/status` | 0.3.1 | cross-repo work dashboard |
| `/retro` | 0.3.1 | team retrospective |
| `/ci-check` | 0.3.1 | post-PR CI watcher |
| `/memory-lint` | 0.3.1 | auto-memory drift audit (new in 0.2.0) |

## Hash Ledger (auto-managed — do not edit by hand)

Generated 2026-06-11 at version 0.3.1.
<!-- Format: filename SHA256 first-8-chars -->

- bootstrap.md           6b33cecb
- build.md               da61457d
- ci-check.md            a1120fb3
- clarify.md              121d0a1b
- do.md                  2fd47c57
- docs.md                1387bc7a
- e2e.md                 fd974d45
- learn.md               4cf22cf3
- memory-lint.md         9b00cd70
- pr.md                  47abacce
- project-context.md     f7676838
- project-debug.md       99904f7a
- qa.md                  42499dd8
- queue.md               1cf6e19a
- refactor.md            1f8b8637
- resume-ticket.md       d422e035
- retro.md               479114b5
- review-comments.md     7c4eeda5
- review-pr.md           1ad3b110
- screenshot.md          924c0869
- status.md              6b4113f6
- ticket.md               fcff0d93
- verify.md              ebff1b45

## Agent Ledger

- codebase-investigator v0.1.0 (workspace)
- jira-context-loader v0.1.0 (workspace)
- commit-drafter v0.1.0 (workspace)
- contract-verifier v0.1.0 (workspace)
- verifier v0.1.0 (workspace fallback — promoted from addin-fe 2026-05-12; repo override at `{REPO_ROOT}/.claude/agents/verifier.md` wins when present)
- pr-branch-reviewer v0.1.0 (workspace fallback — promoted from addin-fe 2026-05-12; repo override at `{REPO_ROOT}/.claude/agents/pr-branch-reviewer.md` wins when present)
- ui-fidelity v0.1.0 (workspace — now reads `{REPO}/.claude/ui-fidelity-ledger.md` `AUTO:META-LESSONS` at Process step 0; meta-lessons synthesized by `/learn` §2.7 from `/verify` §8.5 captures)
