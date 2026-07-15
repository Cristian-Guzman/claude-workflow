---
name: ci-check
version: 0.3.1
description: Post-/pr CI watcher. Waits until CI is green on your open PR, prompts you to merge, then auto-runs /learn. Closes the pipeline loop.
argument-hint: "[PR# — optional, discovers from current branch]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---

<objective>
After `/pr` creates the PR and you push it, the ticket usually lives in limbo until CI finishes and someone approves. This command closes that gap:

1. Identifies the PR for the current branch (or $ARGUMENTS).
2. Polls CI status until green or failed.
3. Surfaces reviewer decisions.
4. Prompts you to merge when safe.
5. After merge, marks the ticket `delivered` and offers `/learn` — completing the pipeline.

Never merges without explicit confirmation. Never skips CI failures.
</objective>

<process>

## 1. Identify the PR

```bash
# If $ARGUMENTS is a number, use it. Else discover from the current branch.
if [[ "$ARGUMENTS" =~ ^[0-9]+$ ]]; then
  PR_NUMBER="$ARGUMENTS"
else
  current_branch=$(git branch --show-current)
  PR_NUMBER=$(gh pr list --head "$current_branch" --json number --jq '.[0].number')
fi

if [ -z "$PR_NUMBER" ]; then
  echo "No PR found for current branch. Push first, then run /ci-check PR#."
  exit 1
fi
```

Also resolve `REPO_NAME` from CWD and the ticket ID from the current branch name (pattern `feature/PROJ-XXXX-*`).

## 1.5 Resolve Base Branch (via repo profile)

Resolve `$BASE_BRANCH` from the repo profile — never hardcode. Mirrors `/pr` and `/verify`:

```bash
PROFILE=$WORKSPACE_ROOT/.claude/repo-profiles/${REPO_NAME}.yaml
if [ -f "$PROFILE" ]; then
  BASE_BRANCH=$(grep '^base_branch:' "$PROFILE" | awk '{print $2}' | tr -d '"')
else
  BASE_BRANCH=$(grep -oE 'base-branch:\s*\S+' {REPO_ROOT}/CLAUDE.md 2>/dev/null | awk '{print $2}')
  : "${BASE_BRANCH:=main}"
  echo "⚠ No repo profile for $REPO_NAME — using fallback $BASE_BRANCH"
fi
```

**Sanity check:** confirm the PR's actual `baseRefName` matches `$BASE_BRANCH`. If not, BLOCK and warn:
> "⚠ PR #{PR_NUMBER} targets `{pr_baseRefName}` but the repo profile says `{BASE_BRANCH}`. Do NOT offer to merge until the PR base is corrected. Run `gh pr edit {PR_NUMBER} --base {BASE_BRANCH}` first."

This catches the class of bugs where a repo uses a non-default base branch recorded in its repo profile (e.g. api-bff targeting `develop-v2`, not `develop`) before auto-merge.

## 2. Fetch PR status

```bash
gh pr view "$PR_NUMBER" --json \
  state,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,headRefName,baseRefName
```

Present a status panel:

```
### PR #{PR_NUMBER}  ({branch} → {base})
  State:             open / closed / merged
  Draft:             yes / no
  Mergeable:         MERGEABLE / CONFLICTING
  Review decision:   APPROVED / REVIEW_REQUIRED / CHANGES_REQUESTED / (null)
  CI status:         PASSING (all green) / PENDING (N of M running) / FAILING (N failed)
```

## 2.6 Post-merge mode

If the PR `state == MERGED`, watch the post-merge runs on the base branch instead:

```bash
MERGE_SHA=$(gh pr view "$PR_NUMBER" --json mergeCommit --jq '.mergeCommit.oid')
gh run list --branch "$BASE_BRANCH" --limit 10 \
  --json databaseId,name,status,conclusion,headSha \
  --jq ".[] | select(.headSha == \"$MERGE_SHA\")"
```

Poll each run with `gh run view <id> --json status,conclusion` until `status == completed`.
Do NOT trust `gh run watch --exit-status` OR `gh pr checks --watch` exit codes — watch can
exit 1 transiently while a run is still `in_progress`, and `gh pr checks --watch` has exited 0
with a FAILED check in the set. Always confirm via a direct `gh run view` / `gh pr checks`
read before reporting either success or failure.

## 3. Decide what to do

Decision tree:

| State | Action |
|-------|--------|
| CI FAILING | Enter the repair loop (Step 3b). Do NOT offer merge. |
| CI PENDING | Poll — sleep 30s and re-fetch. Max 30 minutes of polling. |
| CI PASSING + CHANGES_REQUESTED | Stop. Suggest `/review-comments` to triage. Do NOT offer merge. |
| CI PASSING + APPROVED + MERGEABLE | Offer merge (see Step 4). |
| CI PASSING + REVIEW_REQUIRED | Remind: "reviewer still needs to approve." Offer to ping, but don't auto-merge. |

While polling, show a one-line progress update every poll (so the user isn't in silence):
```
PR #183 — CI: 4/6 checks passing (2 running). Check again in 30s...
```

## 3b. CI-failure repair loop

A red check doesn't end the watch. For each failing check:

1. `gh run view <id> --log-failed | tail -n 120` — load only the failing step's log tail into context; redirect the full log to the ticket state folder if deeper analysis is needed.
2. Apply the cause-known gate (canonical: `routing.md`): if you can name the cause in one sentence (lint error, stale snapshot, missing format:check, env skew), draft the minimal fix. If you cannot, stop and suggest `/project-debug` — don't guess-and-push.
3. Show the diff. Commit + push ONLY after explicit confirmation ([[feedback_confirm_before_commit_push]]), then re-enter Step 2 polling.
4. Max 2 repair rounds. A third red on the same check means stop and suggest `/project-debug`; if the failure is an E2E spec, reproduce locally first ([[feedback_local_e2e_before_blind_ci]]) instead of iterating through CI dispatches.

## 4. Merge prompt

When ready, ask via AskUserQuestion:
> "PR #{PR_NUMBER} is approved and CI is green. Merge now with squash?"
> Options: `Squash & merge` | `Regular merge` | `Rebase & merge` | `Hold off`

Do NOT default — require explicit choice.

If user picks a merge option:
```bash
gh pr merge "$PR_NUMBER" --squash   # or --merge / --rebase
```

If the user picks "Hold off", exit cleanly without touching anything.

## 5. Post-merge actions

Only if the merge succeeded:

1. **Transition the ticket to delivered + snapshot the outcome** — find `{REPO_ROOT}/.claude/tickets/{PROJ-XXXX}.md`.
   - Expected incoming status: `pr-generated` (set by `/pr`). If it's already `delivered` or `learned`, skip the transition — the merge is late to the state file, not first.
   - Set `status: delivered`.
   - Append an event-log line `- [HH:MM] Merged via PR #{PR_NUMBER} to {BASE_BRANCH} (CI-check)`.
   - Do NOT rewrite or truncate existing event-log entries — append only.
   - **Snapshot the Jira outcome while it's freshest** — so `/learn` can render its Closeout without re-fetching, and the QA-bounce signal survives even if the interactive retro is later skipped. Fetch the status changelog per **[[ticket-outcome-spec.md]] → Outcome** and write a frontmatter block:
     ```yaml
     outcome:
       merged_at: YYYY-MM-DDTHH:MM:SSZ
       jira_status: QA            # status at merge time
       qa_bounces: 1              # (transitions toString=='QA') − 1
       timeline: "To Do → In Progress → Code Review → QA → Code Review → QA"
     ```
     This is the changelog-derived subset of the `outcome:` contract in [[ticket-outcome-spec.md]]; cycle time + story points are derived later by `/learn`, not snapshotted here. Best-effort: if Jira auth isn't available (the `--debug` grep is empty), skip this bullet silently — it never blocks the merge.

1b. **Scoped post-deploy E2E re-check** (e2e-enabled repos only — skip silently otherwise). If the state file has an `## E2E Affected Specs (post-deploy re-check)` section (written by `/verify` §3.2c Step 5), the related-only spec list now becomes meaningful: deployed dev is about to serve the merged code. This is the substitute for waiting on the nightly full regression to discover a scoped break.
   - **Merged ≠ deployed** ([[reference_diagnosing_stuck_dev_deploy]]): the run is only valid once the dev deploy lands. Don't poll for it — ask (user-paced, [[feedback_run_commands_discretely]]) via AskUserQuestion:
     > "This ticket has {N} related e2e specs to re-check against deployed dev. Run them now (only if the dev deploy has landed), or I'll leave the command in the state file for when it has?"
     > Options: `Deploy landed — run now` | `Later — keep the command handy`
   - **Run now** → execute the state file's `run:` line as-is (default baseURL = deployed dev, `--workers=1 --reporter=line`). Report per-spec pass/fail. A red here is a real, scoped regression signal tied to THIS merge — name the failing test; per [[feedback_e2e_rot_not_blocking]] pre-existing rot in unchanged specs stays non-blocking.
   - **Later** → print the `run:` command once and append `- [HH:MM] Post-deploy e2e re-check deferred ({N} specs pending)` to the event log. Do not nag again.
   - On a green run, append `- [HH:MM] Post-deploy e2e re-check: {N}/{N} passed (deployed dev)` — this closes the ticket's E2E loop.

2. **Delete the local feature branch** (with confirmation):
   ```bash
   git checkout "$BASE_BRANCH" && git pull --ff-only origin "$BASE_BRANCH"
   git branch -d "$current_branch"
   ```

3. **Offer `/learn`**:
   > "Ticket delivered. Run `/learn` now to extract patterns from the retrospective while context is fresh?"
   - Yes → show the user the single-ticket learn flow for this ticket number.
   - No → remind them `/learn` will pick it up on the next multi-ticket run.

## 6. Summary

```
✓ PR #{PR_NUMBER} merged ({merge_method}) into {BASE_BRANCH}
✓ Ticket {PROJ-XXXX} marked delivered
✓ Jira outcome snapshotted ({qa_bounces} QA bounce(s)) for the /learn Closeout
✓ Local branch {branch} deleted
  → Next: /learn to extract patterns (optional)
```

</process>

<success_criteria>
- [ ] PR identified (from arg or current branch)
- [ ] CI status shown clearly; never offers merge while failing or pending
- [ ] Review decision respected (never merges over CHANGES_REQUESTED)
- [ ] Merge method is explicitly chosen, not defaulted
- [ ] Ticket state file updated on successful merge
- [ ] On merge, the Jira outcome (status timeline + `qa_bounces`) is snapshotted into the state file `outcome:` frontmatter when auth is available (best-effort; never blocks merge)
- [ ] Offers `/learn` after merge — doesn't auto-run it
- [ ] On merge in an e2e-enabled repo whose state file carries `## E2E Affected Specs`, the scoped post-deploy re-check was offered (user-paced, never auto-run, merged≠deployed respected)
</success_criteria>

## Related Commands
- Upstream: `/pr` (creates the PR)
- Downstream: `/learn` (extract patterns after merge)
- Related: `/review-comments` (triage feedback when CHANGES_REQUESTED)
