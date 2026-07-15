---
name: review-pr
version: 0.3.1
model: "opus[1m]"
description: Review someone else's PR against repo conventions AND the ticket's ACs. Combines pattern compliance, AC verification (via /verify logic), CI status, and bimodal confidence into an evidence-backed verdict. Never auto-posts.
argument-hint: "PR-number or PR-URL [--repo repo-name]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
  - Task
---

<objective>
Review a pull request created by another developer. Checks three things, not one:

1. **Pattern compliance** — against codebase-patterns.md, testing-patterns.md, ticket-checklist.md
2. **AC compliance** — does the diff actually satisfy the ticket's ACs? (This is /verify's core logic adapted for external diffs.)
3. **Evidence quality** — CI status, tests-for-every-source, contract-verifier check if APIs touched

Produces a bimodal confidence (author-side + reviewer-side), a decision-tree verdict, and a clean copy-paste comment — shorter than the full report — that you paste after explicit approval. Never auto-posts.
</objective>

<process>

## 0. Detect Target Repository & PR

### Parse Arguments
- If `$ARGUMENTS` is a GitHub PR URL: extract owner/repo and PR number
- If `$ARGUMENTS` is a number: assume current repo's PR
- If `--repo` specified: use that repo

### Detect repo (if not specified)
1. Check CWD — if inside `$WORKSPACE_ROOT/{repo-name}/`, use that
2. If at workspace root, ask which repo via AskUserQuestion

### Fetch PR metadata
```bash
cd {REPO_ROOT}
gh pr view {PR_NUMBER} --json \
  title,body,headRefName,baseRefName,files,additions,deletions,author,state,mergeable,labels \
  > /tmp/pr-${PR_NUMBER}-meta.json
gh pr checks {PR_NUMBER} --json name,state,conclusion > /tmp/pr-${PR_NUMBER}-ci.json
```

Store: **PR_NUMBER, PR_TITLE, PR_AUTHOR, BASE_BRANCH, HEAD_BRANCH, CHANGED_FILES, LABELS, CI_STATUS**.

If `gh` is unavailable, fall back to git + ask the user to paste the PR body. Warn that AC verification will be weaker without GitHub metadata.

## 1. Extract Ticket ID & Fetch ACs

The reviewer doesn't have the author's local ticket state file — ACs come from Jira (or PR body as fallback).

### 1a. Ticket ID extraction (ordered fallback)

```bash
# 1. Branch name — most reliable
TICKET_ID=$(echo "$HEAD_BRANCH" | grep -oE '[A-Z]+-[0-9]+' | head -1)

# 2. PR title
[ -z "$TICKET_ID" ] && TICKET_ID=$(echo "$PR_TITLE" | grep -oE '[A-Z]+-[0-9]+' | head -1)

# 3. PR body (both inline and markdown-linked)
[ -z "$TICKET_ID" ] && TICKET_ID=$(echo "$PR_BODY" | grep -oE '[A-Z]+-[0-9]+' | head -1)

# 4. Labels
[ -z "$TICKET_ID" ] && TICKET_ID=$(echo "$LABELS" | grep -oE '[A-Z]+-[0-9]+' | head -1)

# 5. Linked issues via gh
[ -z "$TICKET_ID" ] && TICKET_ID=$(gh pr view $PR_NUMBER --json closingIssuesReferences -q '.closingIssuesReferences[0].number')
```

If **multiple IDs** across sources, dedupe and treat the branch-name ID as primary. List the rest as "related."

### 1b. Fetch ACs via jira-context-loader

```
Task(
  subagent_type: "jira-context-loader",
  description: "Load ACs for ${TICKET_ID} for PR review",
  prompt: "Load Jira context for ${TICKET_ID}. depth: primary-only.
  Return: summary, type, acceptance criteria, and the 'updated' timestamp."
)
```

### 1c. Merge AC sources

Three possible sources: Jira "Acceptance Criteria" custom field (authoritative), Jira description checklist, PR body `## Acceptance Criteria` section. Extract all three, dedupe by normalizing whitespace + lowercasing. Flag divergences:

- AC in PR body but not Jira → possible **scope creep**
- AC in Jira but not PR body → possibly **missed work**
- Jira `updated` timestamp > PR `createdAt` → **stale AC drift** (ACs changed after PR opened)

### 1d. No-ticket-ID fallback

If no ID extracted (Dependabot, tooling, typo fixes):
- Skip full AC verification
- Substitute "Stated Intent Review" — use the PR body's stated goal as the success criterion
- Mark AC compliance as `N/A — no ticket reference; reviewed against PR body`
- Continue with pattern + CI + quality checks

## 2. Decide Review Strategy

Three strategies; pick based on the PR shape.

| Condition | Strategy |
|-----------|----------|
| Author is a bot (`dependabot[bot]`, `renovate[bot]`) | **Diff-only** — trust CI; focus on lockfile sanity |
| PR is docs-only (all files match `*.md`) | **Diff-only** — no tests to run |
| PR branch was deleted (already merged) | **Fetch PR ref** — `git fetch origin pull/{N}/head:review-{N}` |
| Changed files > 500 | **Diff-only** — recommend splitting |
| Free disk < 2GB | **Diff-only** — worktree needs headroom |
| Default | **Worktree** — non-disruptive, full capability |

### Worktree setup (default path)

```bash
WT=/tmp/review-pr-${PR_NUMBER}
trap 'git worktree remove "$WT" --force 2>/dev/null; git branch -D review-pr-${PR_NUMBER} 2>/dev/null' EXIT

git fetch origin ${HEAD_BRANCH}
git worktree add "$WT" origin/${HEAD_BRANCH}

# Reviewer's current branch, index, working tree stay untouched.
# All /verify-style checks now run against files under $WT/.
```

Cleanup on exit (success or failure) via the trap.

### Diff-only setup

```bash
gh pr diff $PR_NUMBER > /tmp/pr-${PR_NUMBER}.diff
# Work from the diff. Can't run tests locally; rely on CI status.
```

## 3. Load Repo Context

Read repo convention files (skip any that don't exist):
- `{REPO_ROOT}/CLAUDE.md`
- `{REPO_ROOT}/.claude/codebase-patterns.md` — if `codebase-patterns-index.md` exists, load the sections relevant to the changed files, not the whole file
- `{REPO_ROOT}/.claude/testing-patterns.md`
- `{REPO_ROOT}/.claude/ticket-checklist.md`
- `.claude/repo-profiles/{REPO_NAME}.yaml` for base branch, CI command, feature areas

If none exist, warn: "This repo has no pattern files. Reviewing with general best practices only."

## 4. Pattern Compliance Check

Run automated checks against CHANGED FILES ONLY.

### 4a. Universal
```bash
# Console/debug left in
grep -n "console\.log\|console\.warn\|console\.error\|debugger" {changed_files}

# TODO/FIXME added in this PR
git diff origin/${BASE_BRANCH}...origin/${HEAD_BRANCH} | grep "^+" | grep -i "TODO\|FIXME\|HACK"
```

### 4b. JS/TS
```bash
grep -n ": any\b" {changed_files}
grep -n "#[0-9a-fA-F]\{6\}" {changed_files}       # hardcoded hex colors
grep -n "<input\|<select\|<textarea\|<button" {changed_files}  # native HTML when components expected
```

### 4c. Go
```bash
grep -n "fmt\.Print" {changed_files}
grep -n "^\tpanic(" {changed_files}
```

### 4d. Pattern file violations

For each rule in `codebase-patterns.md`, check if any changed file violates it. Skip rules irrelevant to the changed files (e.g. Go patterns for `.tsx` diffs).

### 4e. Deletion safety (symbol-removing / net-negative diffs)

When the diff removes exported symbols, routes, or query options (caught the PROJ-6389 / PR #1000 net-deletion review):

```bash
# Reachability: every deleted export must have NO surviving reference. Type-check catches dead
# imports, but not a half-removal in an untyped call site or a feature the ticket never scoped.
gh pr diff $PR_NUMBER | grep -E '^-' | grep -oE 'export (async )?(function|const|class|interface|type) [A-Za-z0-9_]+' \
  | awk '{print $NF}' | sort -u | while read sym; do
    n=$(grep -rn --include=*.ts --include=*.tsx "\b$sym\b" "$WT" 2>/dev/null | grep -vc '\.test\.')
    [ "$n" -gt 0 ] && echo "SURVIVING REF: $sym ($n) — dead import or half-removal"
  done
```

Map every removed user-facing surface (route/copy/handler in the `^-` lines) to an AC or the PR's
stated intent. An unexplained removal is a WARNING (coordinate); a removed surface a spec still
references is a blocker.

## 5. AC Verification

Per-AC substance check against the diff. For each AC:

1. **What must be TRUE** for this AC to be met? (derive one crisp sentence)
2. **Which file(s) in the diff implement this truth?**
3. **Is the implementation real?** — not a stub, placeholder, empty handler, TODO
4. **Is it wired?** — imported, rendered, called from a reachable code path

Status per AC: **PASS / PARTIAL / FAIL / NEEDS_MANUAL**.

### 5a. Tests-for-every-source check

```bash
# For each net-new source file in the diff, check for a matching test file
for src in $(gh pr diff $PR_NUMBER --name-only | grep -E '\.(ts|tsx|js|jsx|go|py|rb)$' | grep -vE '\.test\.|\.spec\.|_test\.|__tests__'); do
  base=$(basename "$src" | sed -E 's/\.(ts|tsx|js|jsx|go|py|rb)$//')
  # Look in the diff itself for a corresponding test file
  matching_test=$(gh pr diff $PR_NUMBER --name-only | grep -E "/${base}\.(test|spec)\.|${base}_test\." | head -1)
  [ -z "$matching_test" ] && echo "MISSING TEST: $src"
done
```

### 5b. Contract smoke test (if API surface touched)

If changed files contain API calls or endpoint definitions:

```
Task(
  subagent_type: "contract-verifier",
  description: "Check PR's API contract changes",
  prompt: "Verify API contract for PR #${PR_NUMBER}.
  endpoints: {extracted from diff}
  ts_types_paths: {modified type files}
  swagger_paths: $WORKSPACE_ROOT/.claude/api-reference/*.json
  mode: static  # live mode requires PR branch running locally
  consumer_repos: {from repo profile bff_depends_on, if this repo is a producer}"
)
```

## 6. Quality Gates

### 6a. CI results (always)

```bash
gh pr checks $PR_NUMBER --json name,state,conclusion
```

Categorize each check: **passing / failing / pending**. Record failing check names.

### 6b. Run tests locally (worktree mode only)

Trust CI for the full suite. Spot-check selectively:
- If CI is **green** and the PR adds new test files → run just those: `yarn test {new-test-files} --run`
- If CI is **red** → reproduce locally to get specifics. Can't say "fix X" without reading the failure.
- If CI is **pending** → skip local run; note in report, suggest re-running `/review-pr` after CI finishes.

```bash
cd "$WT"
# Run based on repo profile's test_command
{ci_command from repo profile} 2>&1 | tee /tmp/review-${PR_NUMBER}-local-ci.log
```

## 6.5 Finding Gate & False-Positive Skip-List

Every check in §4–§6 produces *raw* findings. Before any finding reaches the report or the verdict, it must pass the **Pre-Report Gate**. This is the primary defense against manufactured/low-value findings — the recurring failure mode where a review is padded with noise. **A review that emits zero findings is a valid, good review.**

### 6.5a Pre-Report Gate (apply to every finding)

Report a finding ONLY if all four are true. If any is "no" → downgrade its severity or drop it entirely.

1. **Locatable** — I can cite an exact `file:line` in *this diff* (not a vague "somewhere in the codebase").
2. **Concrete failure** — I can name what actually breaks (a behavior, a contract, a test), not "this could theoretically…".
3. **Read the context** — I read the callers/tests around the change, not just the diff hunk.
4. **Severity defensible** — HIGH/CRITICAL requires *proof* (a failing test, a broken contract, a reproduction). If I can't prove it, it's at most a LOW/nit — or it's dropped.

### 6.5b Project skip-list — do NOT report these

Settled conventions and known non-issues. Flagging them is noise (sourced from standing memory):

- **Mocks-first / "data may not be wired" warnings** on tickets that are intentionally mocks-first — don't add speculative-plumbing caveats from absence-of-grep-evidence. ([[feedback_no_speculative_plumbing_warnings]])
- **Pre-existing E2E spec rot** in nightly-cycle repos — surface as a non-blocking note only; NEVER flip the verdict to REQUEST/DISCUSS on it. ([[feedback_e2e_rot_not_blocking]])
- **api-bff `String()`-wrapping** of `string | undefined` in template literals — that's the *required* lint rule, not a smell. **No trailing commas** likewise (project lint rule), not a style nit.
- **`!text-white` / important modifiers on `<a>` tags** in addin-fe — `globals.css` sets `a { color: inherit }`, so the important modifier is the correct fix, not a hack.
- **`any` already present** in unchanged lines — only flag `any` *introduced* by this diff.

### 6.5c Do NOT skip — surface as a coordinated-change prompt

- **PostHog feature-flag key rename** — if the diff renames a `FeatureFlag` enum string value, the new key must exist in PostHog FIRST, or the gated feature silently disables (missing key coerces to `false`). CI and unit tests cannot catch this. Surface it explicitly as a deploy-ordering requirement, not a code nit. ([[feedback_flag_rename_needs_posthog_first]])

### 6.5d Author carve-out

- **PRs from an auto-reviewed teammate** (if your repo has a per-author auto-review workflow, e.g. `.github/workflows/auto-review-<author>.yml`): note that the automated review owns the verdict and do not duplicate/conflict with it unless explicitly asked. ([[feedback_auto_approve_teammate_prs]])

## 7. Confidence Calibration (Bimodal)

Two confidence levels, rendered as min() for the headline. **All findings considered here are post-Gate (§6.5)** — raw checks that failed the Pre-Report Gate never reach confidence or the verdict.

### 7a. Author Confidence (AC) — proxy for what /verify would say

| Level | Criteria |
|-------|----------|
| **HIGH** | CI green + every AC mapped to a diff hunk + new source files have tests + contract-touching changes include smoke test or swagger diff |
| **MEDIUM** | CI green + ACs addressed but tests thin OR contract change with no evidence |
| **LOW** | CI red/pending, ACs missing, or net-new source with zero tests |

### 7b. Reviewer Confidence (RC) — honest self-assessment

| Level | Criteria |
|-------|----------|
| **HIGH** | Worktree checkout + ran affected tests locally + read every changed file + traced one end-to-end path |
| **MEDIUM** | Read every changed file, spot-checked one critical path. Diff-only reviews **cap at MEDIUM**. |
| **LOW** | Skimmed only, or large diff in unfamiliar area, or time-boxed |

### 7c. Headline = min(AC, RC)

Report shows both. Example: `Verdict: MEDIUM (Author: HIGH · Reviewer: MEDIUM — diff-only)`

### 7d. Gaming guards

- **RC requires evidence**: the review form has fields for "commands run", "files read count / files changed count", "minutes spent". HIGH RC with empty fields auto-downgrades to MEDIUM.
- **Diff-only is structurally capped at RC=MEDIUM** — the only path to HIGH is worktree + local run.
- **Trust does NOT raise AC**. Recurring contributor gets the same calibration as a first-time author; trust only affects tone, not the verdict.

## 8. Positive Observations

Look for and cite 2–3 things the author did well:
- Clean abstractions, good test coverage, proper error handling, following established patterns, clear naming, helpful comments on complex logic, tight scope (no unrelated touches)

Always include at least one. Every review has something to recognize.

## 9. Verdict Decision Tree

```
function decideVerdict(evidence):
  # TRUMP LAYER (any match → REQUEST CHANGES, short-circuit)
  if ci == RED:                              return REQUEST("CI red")
  if patterns.critical > 0:                  return REQUEST("critical pattern violation")
  if tests.missing_for_new_src:              return REQUEST("source without tests")
  if confidence.headline == LOW:             return REQUEST("AC not demonstrably met")

  # DISCUSS LAYER (evidence good, reviewer-judgment signals)
  if reviewer.architectural_disagreement:    return DISCUSS("design choice worth a chat")
  if reviewer.simplification_idea:           return DISCUSS("simpler path available")
  if confidence.headline == MEDIUM
     and patterns.warning >= 3:              return DISCUSS("pattern drift pattern")
  if ci == PENDING:                          return DISCUSS("wait for CI, re-run /review-pr")

  # APPROVE LAYER
  if confidence.headline == HIGH
     and patterns.critical == 0
     and patterns.warning <= 2
     and ci == GREEN
     and tests.present:                      return APPROVE()

  if confidence.headline == MEDIUM
     and patterns.warning <= 2
     and ci == GREEN
     and tests.present:                      return APPROVE_WITH_COMMENTS()

  return DISCUSS("evidence ambiguous")  # safe default
```

### Trump signals (force REQUEST CHANGES, no override without explicit user confirmation)
- CI red
- Any **critical** pattern violation (security, data loss, breaking API, missing auth check)
- New source file with NO corresponding test
- LOW headline confidence

### DISCUSS criteria (not a block — "would approve, but...")
- Architectural disagreement (e.g., new Redux slice where useQuery would do)
- Simplification available (verbose reducer where 20-line reduce() works)
- Smells like premature OOP / over-engineering
- Introduces coupling (new component imports from 4 feature folders)

### Gut-check gotcha

Before finalizing, if the tree suggests APPROVE but the reviewer's intuition disagrees, ask ONCE:

> "Decision tree suggests APPROVE. Anything bugging you? One sentence."

If the reviewer types a concern, scan the diff for supporting evidence:
- "feels over-engineered" → flag files with cyclomatic complexity >10
- "tests feel thin" → list assertions per test
- "naming feels off" → identify ambiguous identifiers

Include the evidence in the review. If nothing surfaces, output: *"No supporting evidence found — trust your gut or reconsider approve."*

## 10. Present the Review

Two outputs: a **full report** (for the reviewer's own worksheet) and a **copy-paste comment** (what goes on the PR, shorter and humane).

### 10a. Full report (for reviewer)

Always rendered inside a single ``` ```markdown ``` ``` block so it's one-copy-shot.

```markdown
┌──────────────────────────────────────────────────────────────────┐
│ Confidence: {HIGH/MEDIUM/LOW}  │  Verdict: {APPROVE/REQUEST/DISCUSS}  │  {N} findings │
└──────────────────────────────────────────────────────────────────┘

PR #{PR_NUMBER} · {TICKET_ID}: {PR_TITLE} · @{PR_AUTHOR}
{HEAD_BRANCH} → {BASE_BRANCH} · {N} files (+{additions} / -{deletions})
Confidence: Author={AC} · Reviewer={RC} · Headline=min={HEADLINE}  [{strategy: worktree | diff-only | fetch-ref}]

### Acceptance Criteria ({N})
| # | AC | Status | Why |
|---|----|--------|-----|
| 1 | {ac text} | PASS / PARTIAL / FAIL / N_M | {one-line reason with file:line} |

(Collapse to <details> if >8 ACs; keep FAIL/PARTIAL visible above fold)

### Pattern Violations
CRITICAL ({N})
- `file:line` — {issue, with citation to codebase-patterns.md section}

WARNING ({N})
- `file:line` — {issue}

NIT ({N} — collapse this sub-section if empty)
- `file:line` — {issue}

(Entire section hidden if totals are 0/0/0)

### CI
(Shown only if any check failed or is pending)
- `{check name}` — {failing | pending} — {output summary}

### AC Source
(Shown when there's anything to flag)
- Jira field vs PR body divergence: {list}
- Stale ACs: Jira updated {date} after PR opened {date} — confirm scope

### What's Done Well
- **{Title}**: {specific detail with file reference}
- **{Title}**: {another specific positive}

### Verdict: {APPROVE / APPROVE WITH COMMENTS / REQUEST CHANGES / DISCUSS}
{1–3 sentences. If REQUEST: list blockers. If DISCUSS: list questions. If APPROVE: 1-line summary of what worked.}
```

### 10b. Copy-paste comment (for PR)

Shorter than the full report — the reviewer's notes stay private; the PR comment is the delivered verdict. 8–12 lines target:

```markdown
**Confidence: {HEADLINE} · Verdict: {VERDICT}**

{One sentence of positive framing — what was done well.}

{If blockers — numbered list, max 3 items, each with file:line}
1. **{Blocker title}** — `{file:line}`. {What's wrong, one suggestion.}

{If non-blockers — "Non-blocking:" line, one sentence grouping the warnings.}

{If DISCUSS — the design question in one sentence.}
```

**Length budget:** full report ≤ 80 lines. Copy-paste comment ≤ 15 lines. If the PR is complex enough to need more, the discussion belongs in a call, not the PR thread.

## 11. Approval Gate — Post to GitHub

**STOP. Wait for explicit user confirmation before posting.** Honors `feedback_never_post_pr_comments.md`.

Ask:
> "Post the copy-paste comment to PR #{PR_NUMBER}?
> - **approve** — submit as approval
> - **request changes** — submit as REQUEST_CHANGES
> - **comment** — submit as plain comment
> - **edit** — show the comment draft in an editor for changes first
> - **skip** — keep the full report private, don't post"

Only post on explicit `approve` / `request changes` / `comment`. On `edit`, show the draft in the AskUserQuestion flow and wait for the edited version before posting.

```bash
# approve
gh pr review $PR_NUMBER --approve --body "$(cat /tmp/review-${PR_NUMBER}-comment.md)"

# request changes
gh pr review $PR_NUMBER --request-changes --body "$(cat /tmp/review-${PR_NUMBER}-comment.md)"

# comment
gh pr review $PR_NUMBER --comment --body "$(cat /tmp/review-${PR_NUMBER}-comment.md)"
```

## 12. Feedback Loop into /learn

Write a review-log file: `{REPO_ROOT}/.claude/tickets/${TICKET_ID}-pr${PR_NUMBER}-review.md` with:
(PR-scoped so a second PR on the same ticket never clobbers a prior review log — see the PROJ-6389
PR #991 → #1000 collision. If a legacy `${TICKET_ID}-review.md` exists, leave it and add a
`prior_review:` pointer to it in the frontmatter.)
```yaml
---
id: ${TICKET_ID}-pr${PR_NUMBER}-review
kind: review
pr: ${PR_NUMBER}
reviewed_by: {your username}
author: ${PR_AUTHOR}
reviewed_at: {timestamp}
strategy: worktree | diff-only | fetch-ref
confidence_author: HIGH|MEDIUM|LOW
confidence_reviewer: HIGH|MEDIUM|LOW
confidence_headline: HIGH|MEDIUM|LOW
verdict: APPROVE | APPROVE_WITH_COMMENTS | REQUEST_CHANGES | DISCUSS
findings_critical: {N}
findings_warning: {N}
tests_run_locally: true|false
time_spent_minutes: {N — ask user}
---
{full report body}
```

`/learn` will later correlate these against outcomes (reverts, follow-up bugfix PRs) to surface reviewer calibration drift: "your HIGH/HIGH reviews miss issues 18% of the time in unfamiliar modules — consider capping at MEDIUM there."

</process>

<guidelines>

## Review Philosophy

1. **Evidence-backed, not vibes-backed.** Every finding cites `file:line` or an AC number. "Feels off" without evidence is a gut-check prompt, not a review item.
2. **Patterns over preferences.** Cite `codebase-patterns.md §N` when possible. "Pattern X says..." carries more weight than "I'd prefer...".
3. **Catch what CI can't.** Logic errors, missing edge cases, scope creep, AC gaps. Don't re-run what the linter already reports.
4. **Always recognize good work.** At least one positive observation per review.
5. **Don't block on nits.** APPROVE_WITH_COMMENTS exists for a reason.
6. **The decision tree recommends; the reviewer decides.** Gut-check gotcha gives the reviewer an override path with evidence collection.

## What NOT to Review

- Formatting already handled by linter/prettier
- Import ordering if auto-sorted
- Code that existed before this PR (unless the PR makes it worse)
- Personal style preferences not backed by a pattern

## Non-Negotiables

- **Never auto-post a comment.** Always explicit user approval.
- **Diff-only reviews cap RC at MEDIUM.** No exceptions.
- **Author context does not modify the verdict.** A senior's PR and a junior's PR get the same calibration — only tone changes.

</guidelines>

<success_criteria>
- [ ] PR metadata fetched (title, body, diff, CI, labels)
- [ ] Ticket ID extracted via fallback chain (branch → title → body → labels → linked issues)
- [ ] ACs fetched via jira-context-loader; AC source divergences flagged
- [ ] Review strategy selected (worktree default; shortcuts for bots/docs/large PRs)
- [ ] Pattern compliance checked against CHANGED FILES ONLY
- [ ] AC verification performed per-AC with PASS/PARTIAL/FAIL/NEEDS_MANUAL status
- [ ] Tests-for-every-source enforced on new source files
- [ ] Contract smoke test run if API surface touched (via contract-verifier agent)
- [ ] Bimodal confidence calibrated (Author + Reviewer); headline = min()
- [ ] Verdict derived from decision tree with trump-signal precedence
- [ ] Gut-check gotcha triggered when tree suggests APPROVE but reviewer has concerns
- [ ] Full report ≤80 lines; copy-paste comment ≤15 lines
- [ ] At least one positive observation included
- [ ] User explicitly approved before anything was posted to GitHub
- [ ] Review log written to `.claude/tickets/{TICKET_ID}-pr{PR_NUMBER}-review.md` (PR-scoped; never clobbers a prior review) for /learn correlation
- [ ] Worktree cleaned up on exit (trap fires on success and failure)
</success_criteria>

## Related Commands
- Before this: `/verify` (author verifies their own ACs)
- After this: author addresses feedback; may re-run `/review-pr` for re-review
- Agents used: `jira-context-loader` (ACs), `contract-verifier` (API contract)
- Feedback loop: `/learn` correlates review log against outcomes to calibrate reviewer confidence over time
- Patterns: `codebase-patterns.md` | `testing-patterns.md` | `ticket-checklist.md` | `.claude/repo-profiles/{repo}.yaml`
