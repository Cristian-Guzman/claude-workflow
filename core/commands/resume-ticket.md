---
name: resume
version: 0.10.2
description: Resume an interrupted ticket, debug, build, refactor, cover or triage session from saved state.
argument-hint: "[PROJ-XXXX | debug-slug | cover--<slug> | triage--<slug>]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Write
  - Edit
  - Task
  - AskUserQuestion
  - TodoWrite
---
> **Model floor: sonnet** — reads state, resumes. This is guidance, not a pin: the command inherits the session model. Opus adds nothing here; Sonnet keeps its full power.

<objective>
Resume work from a previously interrupted ticket, debug, build, refactor, cover, or triage session.
Scans all repos for active state files, reconstructs context, and continues from exactly where work stopped.
</objective>

<process>

## 1. Find Active Sessions

If $ARGUMENTS specifies a ticket number or debug slug, search for that specific state file across all repos.

Otherwise, scan ALL repos for active sessions:

```bash
for dir in "$WORKSPACE_ROOT"/*/; do
  repo=$(basename "$dir")
  for f in "$dir/.claude/tickets/"*.md "$dir/.claude/debug/"*.md "$dir/.claude/builds/"*.md "$dir/.claude/refactors/"*.md "$dir/.claude/e2e/"*.md; do
    [ -f "$f" ] && echo "$repo: $f"
  done
done 2>/dev/null
```

Parse the frontmatter of each file to check status. The `tickets/` glob also returns the ticket-less sidecars `tickets/<kind>--<slug>.md` (`kind: cover|triage`, see `state-file-schema.md` → Kinds) — type them by their `kind:` frontmatter, not by directory. List active sessions:

| # | Repo | Type | ID | Status | Current Focus |
|---|------|------|----|--------|---------------|
| 1 | addin-fe | Ticket | [[PROJ-1234]] | implementing | Working on AC2 |
| 2 | addin-fe | Build | orders-v2-ui | implementing | Fixing InlineEditField |
| 3 | addin-fe | Refactor | orders-v2 | planning | 12 violations found |
| 4 | api-bff | Debug | api-null-error | investigating | Testing hypothesis 3 |
| 5 | web-app | Cover | orders-v2-checkout | in-progress | Scenario 3 of 5 — no break-to-validate receipt yet |
| 6 | web-app | Triage | nightly-2026-04-21 | env-blocked | Cluster 2 of 3 unresolved (env-or-data) |

If multiple active sessions, use `AskUserQuestion` to ask which to resume.

## 2. Load State File & Repo Config

Read the full state file.

Determine the repo from the state file's `repo` field or from its file path. Then load repo config:
- Read `{REPO_ROOT}/CLAUDE.md` for conventions and commands
- Check for `{REPO_ROOT}/.claude/codebase-patterns.md` → read if exists
- Check for `{REPO_ROOT}/.claude/testing-patterns.md` → read if exists
- Check for `{REPO_ROOT}/.claude/ticket-checklist.md` → read if exists

**If `{REPO_ROOT}/CLAUDE.md` does NOT exist**, warn the user:
> "This repo ({REPO_NAME}) doesn't have a CLAUDE.md. I can resume from saved state, but I won't know repo conventions. Results may differ from the original session if it relied on CLAUDE.md."

## 3. Reconstruct Context

### For Tickets:

1. **Refresh from Jira** — Check if ACs or description changed since last session (try in order):
   - **MCP**: `mcp__atlassian__getJiraIssue` if available
   - **CLI**: `jira issue view PROJ-XXXX --plain`
   - If both unavailable, skip refresh and use saved state as-is.
2. **Read the ACs** — know what's done vs pending
3. **Read files already modified** — understand what was built so far
4. **Read the plan summary** — understand the approach and decisions
5. **Read decisions made** — don't re-ask resolved questions
6. **Read current focus** — know exactly where to pick up

Set up `TodoWrite` with:
- Completed ACs marked as `completed`
- Next AC marked as `in_progress`
- Remaining ACs as `pending`

### For Build / Refactor Sessions:

1. **Read the scope** — understand what was being built/refactored
2. **Read the plan summary** — understand the approach
3. **Read files modified** — understand what was done so far
4. **Read current focus** — know where to pick up
5. **Read implementation progress** — know which phase is active
6. For refactors: **Read violations table** — know what's fixed vs pending

Set up `TodoWrite` from the progress table.

### For Cover / Triage Sidecars:

1. **Read `ticket:`** — `null` means ticket-less; do not try a tracker refresh (`/log` keys it later)
2. **Cover:** read the scenario table — each row carries a break-to-validate receipt `{mutation, cmd, exit, failure, reverted}` once validated; rows without one are the unfinished work
3. **Triage:** read the cluster table — each row carries a class (`broken-test | env-or-data | flaky | real-app-bug`) and a resolution; rows without a resolution are the unfinished work
4. **Read `## Files Modified` + the Event Log** — specs written so far, the last gate score / run result, and whether `env-blocked` was set (and why)

Set up `TodoWrite` from the table: validated/resolved rows `completed`, the first open row `in_progress`, the rest `pending`.

### For Debug Sessions:

1. **Read hypotheses tested** — don't re-investigate eliminated hypotheses
2. **Read evidence log** — understand what's been discovered
3. **Read current focus** — know which hypothesis to test next
4. **Read the trigger** — understand the original problem

## 4. Continue Work

### For Tickets:

Determine current phase from the progress table and continue:

| Phase Status | Action |
|-------------|--------|
| Plan IN_PROGRESS | Continue investigation, create plan |
| Implementation IN_PROGRESS | Continue implementing next pending AC |
| Testing IN_PROGRESS | Continue writing tests |
| Verification IN_PROGRESS | Continue running verification checks |
| Delivery PENDING | Generate commit message + PR description |
| Delivered (DONE) | Ask if PR was merged. If yes, set status → `learned` (run `/learn`). If no, ask what needs changing. Never delete the file. |

Follow the repo's `ticket-checklist.md` (if available) from the current phase forward.
Use the repo's CLAUDE.md for commands and conventions.

**If ticket status is `delivered`:** The ticket was already completed. Ask the user:
- "PR merged?" → Set status → `learned` (or run `/learn`). State files are **never deleted** — they stay on disk for retro, /status, and prior-art lookup.
- "Need changes" → Set status back to `in-progress`, continue work

### For Build / Refactor Sessions:

Continue from the current phase in the progress table:
- Read the plan and follow it from where work stopped
- For refactors: fix the next pending violation from the violations table
- Follow `codebase-patterns.md` and `testing-patterns.md` (reload fresh from disk)
- Update the state file as work progresses

### For Cover / Triage Sidecars:

- **Cover** → resume at the **first scenario without a break-to-validate receipt**: re-run that spec, apply the mutation, confirm it fails, revert, record the receipt — then the next. All rows receipted → re-run the gate (`/cover` writes the `gate score=NN` event) and hand to `/pr-creation`.
- **Triage** → resume at the **first unresolved cluster** (largest first if several): reproduce, classify, apply the class's resolution; a `real-app-bug` cluster stays red and gets a `/log --bug` draft, never a skip.
- `status: env-blocked` → first re-check the blocker named in the Event Log (deploy landed? data seeded? auth back?). Still blocked → stop and say so; do not grind against the environment.
- `status: delivered` → same as tickets: ask whether to run `/learn`; sidecars are never renamed or deleted.

### For Debug Sessions:

Continue debugging from the current hypothesis:
- Skip eliminated hypotheses (already tested)
- Start from Current Focus / next action
- If `{REPO_ROOT}/.claude/agents/debugger.md` exists, follow its methodology

## 5. Maintain State

Continue updating the state file as work progresses (same rules as /ticket command).

</process>

<success_criteria>
- [ ] Active sessions found and listed (across all repos)
- [ ] State file loaded and parsed
- [ ] Repo config loaded (CLAUDE.md, patterns files)
- [ ] Context reconstructed (ACs, files, decisions, current focus)
- [ ] Work continues from exact interruption point
- [ ] No re-asking of already-resolved questions
- [ ] State file continues to be updated
</success_criteria>

## Related Commands
- Resumes: /ticket | /build | /project-debug | /refactor | /e2e | /cover | /triage
- Continue with: /verify | /pr-creation | /test
