---
name: pr-creation
version: 0.10.1
description: Generate PR deliverables (commit message + PR description) from current changes. Resolves the branch's state file via the index for any kind (ticket, build, cover, triage).
argument-hint: "[PROJ-XXXX] — optional; ticket-less branches (test/<slug>) resolve their state file by branch"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Task
---
> **Model floor: sonnet** — commit message + PR body from a diff. This is guidance, not a pin: the command inherits the session model. Opus adds nothing here; Sonnet keeps its full power.

<objective>
Generate commit message and PR description from the current branch changes.
Detects the target repo, optionally invokes pr-branch-reviewer agent for a final quality check.
</objective>

<process>

## 0. Detect Target Repository

1. **Check current working directory** — if CWD is inside a sub-repo of `$WORKSPACE_ROOT/{repo-name}/`, use that repo. **IMPORTANT:** `$WORKSPACE_ROOT/` itself is NOT a valid target — it's the workspace root. Only match if CWD is at least one level deeper.
2. **Parse $ARGUMENTS** for repo hints
3. **If still ambiguous**, list repos and **always ask the user** using `AskUserQuestion`:
   ```bash
   ls -d $WORKSPACE_ROOT/*/CLAUDE.md 2>/dev/null
   ```

Load repo config:
- Read `{REPO_ROOT}/CLAUDE.md` for conventions
- Check for `{REPO_ROOT}/.claude/pr-template.md` → use if exists
- Check for `{REPO_ROOT}/.claude/ticket-checklist.md` → reference if exists
- Check for `{REPO_ROOT}/.claude/agents/pr-branch-reviewer.md` → use if exists

**If `{REPO_ROOT}/CLAUDE.md` does NOT exist**, warn the user:
> "This repo ({REPO_NAME}) doesn't have a CLAUDE.md. I'll generate PR deliverables with generic conventions, but commit format, branch naming type derivation, and PR template will use defaults — not repo-specific rules."

## 1. Suggest Branch Name (if not on a feature branch)

Check the current branch:
```bash
git -C {REPO_ROOT} branch --show-current
```

**Already-merged-branch check (fix-forward detection).** If the current branch's PR already MERGED and the working tree has new changes, this is a fix-forward — NEVER append to the merged branch (post-squash the local branch shows "1 ahead / 1 behind": that's squash divergence, not new work; appending re-introduces merged code or yields a no-op PR):
```bash
BRANCH=$(git -C {REPO_ROOT} branch --show-current)
git -C {REPO_ROOT} status --porcelain | head -3
gh pr list --repo "$(git -C {REPO_ROOT} remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')" \
  --head "$BRANCH" --state merged --json number,mergedAt --jq '.[0]' 2>/dev/null
```
If a merged PR exists AND there are uncommitted changes: explain the squash divergence, then cut a fresh branch off the base — `git stash` → `git fetch origin` → `git checkout -b <new-fix-branch> origin/$BASE_BRANCH` → `git stash pop` — and suggest the new name from the table below.

If on `main` or `develop` (i.e., no feature branch created yet), suggest a branch name following this convention:

| Type | Format | Example |
|------|--------|---------|
| Feature | `feature/PROJ-XXXX-short-description` | `feature/PROJ-5580-mark-unreviewed-action` |
| Bug fix | `fix/PROJ-XXXX-short-description` | `fix/PROJ-5501-drawer-crash-on-empty` |
| Refactor | `refactor/PROJ-XXXX-short-description` | `refactor/PROJ-5490-extract-review-hook` |
| Chore | `chore/PROJ-XXXX-short-description` | `chore/PROJ-5510-update-dependencies` |
| Test coverage (ticket-less) | `test/<slug>` | `test/orders-v2-checkout` |

Rules:
- Always include the ticket number — except `test/<slug>`, which is `/cover` / `/triage` work that has no ticket until `/log` keys one (`commit-drafter` already handles no-ticket scope and the `test` type)
- Use kebab-case for the description (lowercase, hyphens)
- Keep description to 3-5 words max
- Derive type from ticket type (Story → feature, Bug → fix, Task → chore)

If already on a feature branch, skip this step.

## 1.5 Determine Base Branch (via repo profile)

**Do NOT hardcode `main`.** Read the repo profile for the source of truth:

```bash
REPO_NAME=$(basename {REPO_ROOT})
PROFILE=$WORKSPACE_ROOT/.claude/repo-profiles/${REPO_NAME}.yaml

if [ -f "$PROFILE" ]; then
  BASE_BRANCH=$(grep '^base_branch:' "$PROFILE" | awk '{print $2}' | tr -d '"')
else
  # Fallback to CLAUDE.md override if present, otherwise `main`
  BASE_BRANCH=$(grep -oE 'base-branch:\s*\S+' {REPO_ROOT}/CLAUDE.md 2>/dev/null | awk '{print $2}')
  : "${BASE_BRANCH:=main}"
  echo "⚠ No repo profile for $REPO_NAME at $PROFILE — using fallback $BASE_BRANCH"
  echo "  Create the profile from .claude/repo-profiles/_schema.yaml to silence this warning."
fi
```

**Sanity check:** confirm the base branch exists:
```bash
git -C {REPO_ROOT} show-ref --verify --quiet refs/remotes/origin/$BASE_BRANCH || \
  git -C {REPO_ROOT} show-ref --verify --quiet refs/heads/$BASE_BRANCH
```
If it doesn't, ask the user which branch to use.

**Wrong-base check:** if the current branch isn't descended from `origin/$BASE_BRANCH`, warn before continuing:
```bash
git -C {REPO_ROOT} merge-base --is-ancestor origin/$BASE_BRANCH HEAD 2>/dev/null && echo OK || echo WRONG_BASE
```
On `WRONG_BASE`:
> "⚠ This branch is NOT based on `$BASE_BRANCH`. For repos whose profile records a non-default base branch (e.g. api-bff/web-app use `develop-v2`), merging to the wrong base has caused production issues before. Rebase onto `$BASE_BRANCH`?"

**Profile-vs-reality sanity check** — confirm the profile's `base_branch` matches where the team is actually merging recently. If five recent merges all target a different branch, the profile is stale and `BASE_BRANCH` is probably wrong:

```bash
RECENT_BASE=$(gh -R "$(git -C {REPO_ROOT} remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')" \
  pr list --state merged --limit 5 --json baseRefName \
  --jq '[.[].baseRefName] | group_by(.) | max_by(length)[0]' 2>/dev/null)
if [ -n "$RECENT_BASE" ] && [ "$RECENT_BASE" != "$BASE_BRANCH" ]; then
  echo "⚠ Profile says base_branch=$BASE_BRANCH, but the last 5 merged PRs targeted $RECENT_BASE."
  echo "  Either the profile is stale or you're about to target the wrong branch. Confirm before continuing."
fi
```

**Freshness check — fetch before generating deliverables.** A branch cut from a stale tip conflicts the moment the PR opens (deterministic whenever a sibling PR touched the same files while this one was in flight):
```bash
git -C {REPO_ROOT} fetch origin $BASE_BRANCH --quiet
BEHIND=$(git -C {REPO_ROOT} rev-list --count HEAD..origin/$BASE_BRANCH 2>/dev/null)
```
If `BEHIND > 0`, prompt: "origin/$BASE_BRANCH has {BEHIND} new commit(s) since this branch was created. Rebase before opening the PR? A 2-second fetch now saves a rebase-and-force-push cycle after the PR is already open." Rebase on approval, then continue.

Use `$BASE_BRANCH` everywhere a diff target is needed — never `main` literally.

## 2. Gather Context

```bash
# Identify changed files
git -C {REPO_ROOT} diff --name-only {BASE_BRANCH}...HEAD

# See commit history
git -C {REPO_ROOT} log {BASE_BRANCH}..HEAD --oneline

# See full diff for understanding
git -C {REPO_ROOT} diff {BASE_BRANCH}...HEAD --stat
```

**Resolve the branch's state file (any kind) via the index.** The join key is `branch:`, not the ticket, so ticket-less `cover`/`triage` sidecars resolve exactly like tickets and builds:
```bash
INDEX=$WORKSPACE_ROOT/.claude/state/index.json
MATCH=$(jq -c --arg r "$REPO_NAME" --arg b "$BRANCH" \
  '[.entries[] | select(.repo==$r and .branch==$b and .archived!=true)] | sort_by(.updated) | last // empty' "$INDEX" 2>/dev/null)
STATE_FILE=$(echo "$MATCH" | jq -r '.path // empty'); STATE_KIND=$(echo "$MATCH" | jq -r '.kind // empty')
TICKET=$(echo "$MATCH" | jq -r '.ticket // empty')      # empty for ticket-less work
```
Fallback when the index is missing or nothing matched: `$ARGUMENTS` carries a ticket key → `{REPO_ROOT}/.claude/tickets/PROJ-XXXX.md`; else grep `{REPO_ROOT}/.claude/builds/*.md` and `{REPO_ROOT}/.claude/tickets/*--*.md` for `branch: $BRANCH`. Read `$STATE_FILE` for ACs (tickets) or the scenario/cluster table (cover/triage) and implementation details. No file → continue; every state-file step below is conditional on `$STATE_FILE`.

## 3. Generate Commit Message (via commit-drafter agent)

**Prefer the agent.** If `$WORKSPACE_ROOT/.claude/agents/commit-drafter.md` exists, invoke it:

```
Task(
  subagent_type: "commit-drafter",
  description: "Draft commit for PROJ-XXXX",
  prompt: "Draft a conventional commit for the current branch.
    repo_root: {REPO_ROOT}
    base_branch: {BASE_BRANCH}
    ticket_id: {TICKET, or "none" for ticket-less cover/triage branches}
    ticket_type: {Story|Bug|Task|...}
    ticket_summary: {summary}
    diff_scope: branch

    Return the fenced commit block + 'Why' commentary."
)
```

Use the agent's output verbatim (subject + optional body + optional footer). Do NOT modify unless the user overrides.

**Fallback (inline).** If the agent is not available:

Format: `feat|fix|refactor|chore|docs|test(PROJ-XXXX): brief description`

Rules:
- `feat` for new features
- `fix` for bug fixes
- `refactor` for restructuring without behavior change
- `chore` for non-source maintenance (deps, config)
- Keep the subject under 72 characters total including `type(scope): `
- No AI attribution (no `Co-Authored-By: Claude`, no "Generated with Claude Code") — ever

## 4. Generate PR Description

Use `{REPO_ROOT}/.claude/pr-template.md` if available, otherwise use this format:

```markdown
## Summary
[What this PR does — 1-2 sentences]

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

**Feature-flag key rename → ops-dependency DoD item.** If the diff renames a string literal assigned to a `FeatureFlag` enum member (a removed `= "old-key"` paired with an added `= "new-key"` on the same member — e.g. `app/context/analytics/utils.ts` in addin-fe; the equivalent enum in gdocs-addin):
```bash
git -C {REPO_ROOT} diff $BASE_BRANCH...HEAD -- '**/analytics/utils.ts' | grep -E '^[-+].*=\s*"' | head -10
```
auto-insert an unchecked DoD item: `- [ ] ⚠ PostHog flag '<new-key>' must exist with targeting identical to '<old-key>' BEFORE deploy — the enum string IS the lookup key; a missing key reads as false and silently disables the gated feature for everyone, and neither CI nor unit tests can catch it ([[feedback_flag_rename_needs_posthog_first]])`.

## 5. Run PR Branch Reviewer (if available)

Look for the `pr-branch-reviewer` agent in priority order:
1. `{REPO_ROOT}/.claude/agents/pr-branch-reviewer.md` — repo-specific copy (preferred; has that repo's conventions inlined)
2. `$WORKSPACE_ROOT/.claude/agents/pr-branch-reviewer.md` — workspace generic fallback

If either exists, spawn the agent (the workspace fallback adapts its inline commands to the current repo via CLAUDE.md + repo-profile):

```
Task(
  prompt: "Review the current branch for PR readiness.
    Ticket: PROJ-XXXX
    Repo: {REPO_ROOT}
    Follow pr-branch-reviewer methodology.",
  subagent_type: "pr-branch-reviewer",
  description: "Review PR readiness"
)
```

If no reviewer agent exists, skip this step.

## 5.5 Pre-PR Checklist (auto-check what was done vs skipped)

Before running CI, run four sub-checks. Only (d) blocks.

**a) `/verify` ran — check the event log, not a phase marker** (the old grep looked for a "Verification phase DONE" marker `/verify` doesn't always write; the event-log entry is what it always writes):
```bash
grep -nE '^\- \[[0-9:]{4,5}\] .*(\[verify\]|/verify|Verified)' "${STATE_FILE:-{REPO_ROOT}/.claude/tickets/PROJ-XXXX.md}" 2>/dev/null | tail -1
```
If no verify event exists, warn (pipeline rule [[feedback_verify_before_pr]]):
> "⚠️ `/verify` was not run for this ticket. ACs have not been formally verified against code. Run `/verify` now? (yes/skip)"

For a `kind: cover|triage` state file the verification evidence is the role command's own gate event instead of `/verify` — same warn-not-block semantics:
```bash
grep -nE '^\- \[[0-9:]{4,5}\] (/cover: gate score=[0-9]+|/triage: )' "$STATE_FILE" 2>/dev/null | tail -1
```
Missing → "⚠️ No `/cover` gate (or `/triage` outcome) is recorded for this branch. Run it now? (yes/skip)". Sub-check (b) applies when the event carries `sha=`.

**b) Stale verification.** If the verify event recorded a commit (`sha=<short_sha>`), compare against HEAD:
```bash
git -C {REPO_ROOT} log --oneline {verify_sha}..HEAD 2>/dev/null
```
Commits after the verified SHA → warn: "⚠️ /verify last ran against {verify_sha}; {N} newer commit(s) exist: {list}. Re-run /verify before /pr-creation?" (No SHA in the event → skip this sub-check; ad-hoc commits after verification are exactly how documented-rule violations have shipped before.)

**c) Fast pattern scan on the branch diff** (non-blocking — catches documented-rule violations CI is blind to):
```bash
FILES=$(git -C {REPO_ROOT} diff --name-only $BASE_BRANCH...HEAD -- '*.css' '*.scss' '*.ts' '*.tsx' | grep -vE '\.(test|spec|stories)\.|__tests__|\.claude/')
[ -n "$FILES" ] && (cd {REPO_ROOT} && grep -nE '#[0-9a-fA-F]{3,6}\b' $FILES 2>/dev/null | head -10)          # hardcoded hex
[ -n "$FILES" ] && (cd {REPO_ROOT} && grep -nE ':\s*any\b|<any>|\bany\[\]' $FILES 2>/dev/null | grep -vE 'vi\.mock|test-utils' | head -10)  # any-types
```
Hits → warn: "⚠️ Pattern scan found {N} hex / {N} `any` hits in your diff. Continue with PR, or run /verify for details?" Do NOT block.

**d) Bypass-marker gate (BLOCKING).** Committed QA bypasses are silently dangerous: review reads them as feature code, unit tests test the bypassed branch, CI has no rule for comments. The marker convention exists to be machine-checked — check it:
```bash
git -C {REPO_ROOT} diff $BASE_BRANCH...HEAD | grep -niE 'QA-?BYPASS|DO NOT COMMIT|TODO REVERT|REVERT BEFORE|XXXFIX'
```
Any match → REFUSE to generate deliverables. Print each match with file:line and require the marker reverted first, or an explicit `--allow-bypass-markers` override from the user.

**e) Comment-hygiene gate (BLOCKING).** Linters and CI never check comment style, so noise comments and ref/history comments ship silently. This is the same gate as `/verify` §3.4 — run it here too because the `/ticket` → `/pr-creation` shortcut skips `/verify` (keep the pattern list in sync with §3.4):
```bash
FILES=$(git -C {REPO_ROOT} diff --name-only $BASE_BRANCH...HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.css' '*.scss' '*.go' '*.swift' '*.py' | grep -vE '\.claude/')
[ -n "$FILES" ] && (cd {REPO_ROOT} && git diff $BASE_BRANCH...HEAD -- $FILES \
  | grep -nE '^\+' \
  | grep -iE '(//|/\*|\*|#).*(PROJ-[0-9]+|§|NEW-[0-9]|\bAC[0-9]|Bug [A-Z]\b|used to be|previously|formerly|fix-forward|the first fix|no longer|changed from|is a word, not|, not a )')
```
Any match → REFUSE to generate deliverables; print each `file:line` and require the comment stripped/reworded first (removing a noise comment is a trivial edit — do it, re-run, don't just report). A reasoned exception needs an explicit `--allow-comment` override. Also eyeball the diff's other added comments for reasoning-narration / restating-the-code noise ([[feedback_no_bug_letter_comments]]).

Also surface verification-summary skips when present: security scan skipped → "⚠️ No security scan was run. Quick scan on changed files? (yes/skip)"; Proxyman not connected → informational only.

This step catches the `/ticket` → `/pr-creation` shortcut where verification gets skipped. Sub-checks a–c are reminders; d and e block.

## 6. Run CI Verification

**MANDATORY:** Run the repo's CI command before presenting deliverables.

### 6a. Resolve CI scope from the actual workflow file

Don't assume `yarn ci` covers everything — some repos (e.g. gdocs-addin) run Prettier `format:check` in CI but it's not in the precommit hook or `yarn ci`. The result is "CI is green locally" → "format check fails in PR." Read `.github/workflows/*.yml` to see what CI actually runs:

```bash
# Discover CI step keywords from workflow files
KEYWORDS=$(grep -hE '^\s*run:|^\s*-\s*run:' {REPO_ROOT}/.github/workflows/*.yml 2>/dev/null \
  | grep -ioE '(format:check|format-check|lint|typecheck|type-check|tsc|test|build|prettier)' \
  | sort -u)
echo "CI workflow runs: $KEYWORDS"
```

Then run each detected step (using the package manager appropriate to the repo). If `format:check` appears, run it. If `typecheck` appears, run it. If `lint` appears, run it. The CLAUDE.md or repo-profile `ci_command` is the **baseline**, not the **complete** verification.

### 6b. Run the baseline CI command

```bash
# Read the baseline CI command from repo profile or CLAUDE.md — common examples:
# yarn ci, cd client && yarn ci, swift test, go test ./...
```

- If CI **fails**: fix the issues and re-run. Do NOT present deliverables until CI passes.
- If CI **passes** AND every workflow keyword detected in 6a also passes: proceed to present deliverables.
- If 6a detected `format:check` (or similar) and the baseline command did NOT run it, run it standalone and only proceed once it passes.

## 7. Present to User

Display:
1. **Commit message** (ready to copy)
2. **PR description** (ready to paste)
3. **Files changed list**
4. **PR reviewer findings** (if any issues)
5. **CI status** — confirm it passes
6. **Ready-to-run `gh pr create` command** — always include `--assignee "@me"` so the PR lands in the user's assigned queue on creation

Example:
```bash
gh pr create --base $BASE_BRANCH --assignee "@me" --title "..." --body "..."
```

**IMPORTANT — `/pr-creation` creates the PR end-to-end.** Invoking `/pr-creation` IS the user's authorization to commit, push, and open the PR. After CI is green, run all three (no separate confirmation — the command name is the go):
```bash
git -C {REPO_ROOT} add -A
git -C {REPO_ROOT} commit -m "<subject>" -m "<body>"   # no AI attribution, ever
git -C {REPO_ROOT} push -u origin <branch>
gh pr create --base $BASE_BRANCH --assignee "@me" --title "..." --body "..."   # --assignee "@me" is mandatory
```
Also print the commit message + PR markdown (unformatted) so the user can reuse them. This authorization is scoped to the initial PR only — any FOLLOW-UP commit/push after the PR exists needs a fresh "commit"/"push" from the user ([[feedback_confirm_before_commit_push]]). Never use `--no-verify`. Only act on an explicit `/pr-creation` — never commit/push outside it.

**If the push fails with "Repository not found" (HTTPS 404):** the HTTPS remote isn't carrying your gh token — don't surface the bare 404. Probe both auth paths:
```bash
SLUG=$(git -C {REPO_ROOT} remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?$#\1#')
gh repo view "$SLUG" >/dev/null 2>&1 && echo GH_OK
ssh -T git@github.com 2>&1 | grep -qi 'success' && echo SSH_OK
```
If both succeed, offer to switch the remote and retry: `git -C {REPO_ROOT} remote set-url origin git@github.com:$SLUG.git` → push again. (Recurs on any fresh clone whose origin is HTTPS without a credential helper.)

**Next step:** Once the PR is merged, run /learn to extract lessons from the ticket retrospective into `codebase-patterns.md`. /learn will update `codebase-patterns.md` with lessons from this ticket.

## 8. Update Ticket State

If a state file matched in §2 (`$STATE_FILE` — ticket, build, cover or triage alike; sidecars are never renamed), update it:
- Delivery phase → DONE
- status → **`pr-generated`** (NOT `delivered` — `/ci-check` transitions to `delivered` after the PR actually merges; setting it here would overwrite `/ci-check`'s event-log entry)
- **Write the PR number into the frontmatter** (schema requirement — this is the join key `/ci-check` uses to close the ticket after merge and the `ticket_cycle_time` metric joins on; every `pr-generated` zombie in the index traces to this field being skipped):
  ```yaml
  pr_number: 123
  pr_url: https://github.com/{org}/{repo}/pull/123
  ```
  and log the event: `- [HH:MM] /pr-creation: PR #123 opened against {BASE_BRANCH}`
- Add an `## Obsidian Links` section (if one doesn't already exist) at the end of the file:
  ```
  ## Obsidian Links
  - Branch: {branch-name}
  - PR: #{pr-number} (if PR number is known from deliverables)
  ```
- **Write the `## Process Summary` block (mechanical — derive from the Event Log + git, never ask).** This is the process-telemetry capture that `/learn` §2.7b distills. It MUST be written here, at PR time, because `/pr-creation` is the one command that always runs before a chat can be abandoned — if the user closes the session without ever running `/learn`, this block is what survives:
  ```markdown
  ## Process Summary
  - sessions: {N}           # distinct session starts in the Event Log (classification + /resume-ticket entries)
  - phases: {N}             # from Implementation Progress
  - fix_iterations: {N}     # Event-Log "Hit issue:" + QA-round + review-fix entries
  - debug_sessions: {linked .claude/debug/ slugs, or none}
  - commits: {git rev-list --count origin/{BASE_BRANCH}..HEAD}
  - first_event_to_pr_days: {N}
  - ui_iteration: {copy the ui-iteration Event-Log line if present, else n/a}
  ```
  Every field is countable from data already on disk; if a field can't be derived, write `unrecorded` — never estimate.

**Also check `.claude/builds/`** (only when §2 had no index entry) — if a build state file matches this branch (grep its `branch:` frontmatter, or slug ≈ branch description), update it too: `status: pr-generated` + the PR URL in its Obsidian Links. Build-sourced PRs deserve the same audit trail as ticket-sourced ones.

## 8.5 Transition Jira Ticket to "Code Review"

**No ticket → no-op.** If the matched state file has `ticket: null` (ticket-less `cover`/`triage` work) or the repo profile says `tracker_system: none`, skip this whole step with one line — `⏭ No tracker ticket for this branch — /log keys it to one later` — and continue to §9.

Once the PR is created (or the user confirms it is), transition the Jira ticket from its current status to **Code Review**. This keeps the board accurate and matches the user's workflow convention that open PR = Code Review.

### Assignee gate — only transition tickets assigned to the user

Before transitioning, check the ticket's assignee. The user's rule: do not change Jira state on tickets owned by someone else, even if you opened the PR. Fetch the assignee first:

```
mcp__atlassian__getJiraIssue(
  cloudId: "<YOUR_ATLASSIAN_CLOUD_ID>",
  issueIdOrKey: "PROJ-XXXX",
  fields: ["assignee", "status"]
)
```

Read `fields.assignee.emailAddress`. If it is not the developer's own email (e.g. `you@your-org.com` — from git config or the Jira profile):
> "⏭ Skipping Jira transition — PROJ-XXXX is assigned to {assignee.displayName} ({assignee.emailAddress}), not you. Per your rule, only tickets you own get their state changed."

Proceed with the transition only if assignee matches the user OR the ticket is unassigned.

**Preferred path — MCP Atlassian:**
```
mcp__atlassian__transitionJiraIssue(
  cloudId: "<YOUR_ATLASSIAN_CLOUD_ID>",
  issueIdOrKey: "PROJ-XXXX",
  transition: { id: "<CODE_REVIEW_TRANSITION_ID>" }   # "Code Review" transition — look up per-project via jira CLI or MCP getTransitionsForJiraIssue
)
```

**Fallback — jira CLI** (MCP Atlassian is currently down, so this is the active path):
```bash
# Some projects' CLI state name carries a suffix, e.g. literally "Code Review (1)" — plain "Code Review" 400s. Check yours.
jira issue move PROJ-XXXX "Code Review (1)"
```

Notes:
- The `Code Review` transition id (`<CODE_REVIEW_TRANSITION_ID>`) is per-project — look it up via jira CLI or MCP `getTransitionsForJiraIssue` and record it as `jira_transition_codereview` in `repo-profiles/<repo>.yaml` (the single home for tracker config — see `_schema.yaml`). The CLI fallback may need a state-name suffix (e.g. `(1)`); the MCP numeric id does not.
- If multiple tickets are closed by a single PR (e.g., a shared CVE fix), transition each ticket.
- If the ticket is already in `Code Review`, `QA`, or `Done`, skip the transition (no-op).
- If the MCP transitionJiraIssue call returns an error about transition id not being available, re-fetch available transitions first via `mcp__atlassian__getTransitionsForJiraIssue` — workflow ids can differ per project or issue type.

## 9. Quick Retrospective & Learn Suggestion

While the context is still fresh, ask the user to fill in the retrospective:

> "Before we wrap up, quick retro for PROJ-XXXX:
> 1. **What went well?** (patterns, tools, approaches that worked)
> 2. **What went wrong?** (time wasters, gotchas, wrong assumptions)
> 3. **Anything surprising about the codebase?**
>
> (Type 'skip' to fill this in later with `/learn`)"

If the user provides answers, update the ticket state file's `## Retrospective` section with their responses.

Then suggest `/learn`:

> "Ticket marked `pr-generated`. You now have {N} tickets awaiting merge across your repos.
> Want me to run `/learn` now to extract patterns while we still have context? (yes/no)
>
> You can also run `/learn` later after delivering more tickets — it works best with multiple tickets."

If the user says yes, proceed with the `/learn` flow for this ticket (and any other delivered tickets found).
If no, remind them: "No problem. Run `/learn` anytime — it'll pick up all delivered tickets."

</process>

<success_criteria>
- [ ] Target repo detected
- [ ] Branch name suggested (if on main/develop)
- [ ] Changed files identified from git diff
- [ ] Commit message generated in conventional format
- [ ] PR description generated (using repo template if available)
- [ ] PR branch reviewer ran quality check (if agent available)
- [ ] All deliverables presented as copyable text
- [ ] Initial commit + push + `gh pr create --assignee "@me"` executed — the explicit `/pr-creation` invocation IS that authorization (§7, [[feedback_confirm_before_commit_push]]); any follow-up commit/push after the PR exists needs a fresh user confirmation
- [ ] Bypass-marker gate (§5.5d) passed — no QA-BYPASS / DO-NOT-COMMIT / TODO-REVERT markers in the diff
- [ ] Ticket state updated to `pr-generated` (if exists) — NOT `delivered`; `/ci-check` sets `delivered` after merge
- [ ] `pr_number` + `pr_url` written into the ticket state frontmatter (and matching build state file, if any)
- [ ] State file resolved by `branch:` via `state/index.json` for any kind (§2); for `cover`/`triage` the gate event stood in for `/verify` (§5.5a) and the tracker transition was skipped on `ticket: null` (§8.5)

## Related Commands
- Before: /verify (verify ACs first)
- After merge: /learn (extract patterns)
- Source: /ticket | /build | /cover | /triage (ticket-less sidecars, keyed by branch)
- Patterns: codebase-patterns.md | ticket-checklist.md
</success_criteria>
