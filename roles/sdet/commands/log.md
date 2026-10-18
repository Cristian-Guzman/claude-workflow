---
name: log
version: 0.10.4
description: Mint the tracker record FROM the work, after the fact — a Story/Task for a /cover state file or a Bug for a /triage cluster. Dedupes against open issues, drafts in plain language, asks before creating, writes the key back into the state file (no rename), and offers to prefix the PR. The single tracker-writer of the SDET role; tracker_system none degrades to a local ticket file.
argument-hint: "[<slug> | --bug triage--<run-id>:C<k>] [--no-transition]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Edit
  - Write
  - Task
  - AskUserQuestion
---
> **Model floor: sonnet** — ticket text from work already done. This is guidance, not a pin: the command inherits the session model. Opus adds nothing here; Sonnet keeps its full power.

<objective>
The dev pipeline takes a ticket IN and produces code. The SDET lane runs the other way: the work
exists first (tests on a branch, or a clustered red run) and the tracker record is an OUTPUT — wanted
for visibility, sprint accounting, or because a real bug needs an owner. `/log` is the one place that
writes to the tracker for this role, so dedupe, draft style, the "ask before create" rule and the
assignee gate live once.

It never creates anything without an explicit approval on the shown draft, never renames a state file
(the index id is immutable; `ticket:` in the frontmatter re-keys the entry), and stops after the write-back.
</objective>

<principles>
1. **Ticket as output, not input.** Everything in the draft is derived from the state file; nothing is
   asked that the file already answers.
2. **Dedupe before draft.** An open issue for the same slug/summary gets linked, not duplicated.
3. **Plain language.** PM and support read these: repro steps, expected/actual, environment, evidence
   paths. No code paths, no selectors, no stack frames.
4. **Ask, never auto-create.** The draft is shown; AskUserQuestion decides approve / edit / skip.
5. **Transitions only through the assignee gate**, and only when the user did not pass `--no-transition`.
</principles>

<process>

## 0. Resolve the state file

- `<slug>` given → `{REPO_ROOT}/.claude/tickets/<slug>.md` (accepts `cover--items-create` or
  `items-create`).
- `--bug triage--<run-id>:C<k>` → the triage file and the cluster row `C<k>` (plus its `## Bug drafts`
  block).
- No argument → the current branch: `jq -r --arg b "$(git branch --show-current)" '.entries[] | select(.branch==$b and .archived!=true) | .path' $WORKSPACE_ROOT/.claude/state/index.json`;
  fallback `grep -l "^branch: $(git branch --show-current)$" {REPO_ROOT}/.claude/tickets/*.md`.
  Several matches → AskUserQuestion. None → stop: "No state file for this branch — run `/cover` or
  `/triage` first."
Load the repo profile's tracker block (`tracker_system`, `jira_project`, transition ids) and
`environments.md` (env + deploy-check command, for bug drafts). Read `ticket:` — if it is already set,
offer "update the existing issue's description" instead of creating a second one.

## 1. Dedupe

If `$WORKSPACE_ROOT/.claude/agents/jira-context-loader.md` exists:
`Task(subagent_type: "jira-context-loader", prompt: "search {jira_project} for open issues matching: '<summary words>' OR text ~ '<slug>'; depth primary-only; return key, summary, status, assignee")`.
**Inline fallback**: MCP `searchJiraIssuesUsingJql` → `jira issue list -q 'project = {KEY} AND statusCategory != Done AND text ~ "<words>"' --plain` → nothing (say the dedupe step was skipped).
Matches → AskUserQuestion: "Link to <KEY> (existing) / create new / skip". Linking = write `ticket: <KEY>`
(§5) with an event `linked-existing`; no draft.

## 2. Draft

**Story / Task for a `kind: cover` file**
```
Summary: Automated coverage: <feature> — <N> scenarios (<level tags>)
Type: Task (Story if the repo's convention files test work as stories)
Description:
  What is covered — the scenario table from ## Scenarios, in words (one line per scenario)
  Proof — "<N>/<N> tests fail when broken" (break-to-validate receipts exist in the state file)
  Manual remainder — rows marked manual, with the one-step check each
  Evidence — screenshot/trace paths; PR link if pr_number is set
  Branch: test/<slug>
Labels: automation, e2e (or the repo's own)
```
**Bug for a `kind: triage` cluster** — take the `## Bug drafts` block for `C<k>` as the body:
```
Summary: <one-line title in product language>
Type: Bug
Description:
  Steps to reproduce — from the test's steps, numbered, in words
  Expected — from the assertion
  Actual — from the received value
  Environment — <env>, deployed sha <sha|unknown>, browser/project
  Evidence — trace/screenshot paths (the state file's Evidence section)
  Detected by — "<N> automated tests (kept failing on purpose until this is fixed)"
Priority: the user's call — propose from blast radius (tests affected, tier gating PRs)
```
Never paste code, selectors, file paths of specs, or stack traces into the description.

## 3. Approve

Show the draft. AskUserQuestion: **Create** / **Edit** (free text — apply and re-show once) / **Skip**.
Skip → log `- [HH:MM] /log: draft skipped by user` and stop. Nothing is created on any other path.

## 4. Create — MCP → CLI → none

1. **MCP Atlassian** when available: `createJiraIssue(cloudId, projectKey, issueTypeName, summary, description)`.
2. **jira CLI**: `jira issue create -t <Type> -s "<summary>" -b "<description>" --no-input` (plain-text
   body; the CLI 400s on some fields — on failure fall back to the REST route documented in the
   workspace memory, or print the draft for manual paste).
3. **`tracker_system: none`** (or both routes unavailable): write
   `{REPO_ROOT}/.claude/tickets/<slug>-ticket.md` with the draft + frontmatter
   `kind: ticket-draft`, `for: <slug>`, and stop after §5 with `ticket: local:<slug>-ticket`.
Record the created key `KEY-n`.

## 5. Write back (no rename)

- `Edit` the state file frontmatter: `ticket: KEY-n` and bump `updated`. The PostToolUse upsert
  re-keys the index entry's `ticket` field from the frontmatter; the entry id stays
  `repo:<kind>:<slug>` (ids are immutable — never `mv` the file).
- `--bug`: also write the key into the cluster row (`class` column → `real-app-bug (BUG KEY-n)`) and,
  if the test was quarantined, make sure its annotation reads `BUG KEY-n` (the hook requires the key;
  the row without it is a violation in the next `/triage`). Flaky-ledger rows for the same test get
  the key in `fix`.
- Event: `- [HH:MM] /log: created KEY-n (<Type>) from <slug>[:C<k>]` or `linked-existing KEY-n`.

## 6. PR and transition (optional, gated)

- If `pr_number` is set: offer `gh pr edit <n> --title "KEY-n: <current title>"` (AskUserQuestion yes/no).
- Transition to Code Review ONLY when: `--no-transition` absent, a PR exists, the state status is
  `pr-generated` or later, and the **assignee gate** passes (`/pr-creation` §8.5: the issue is assigned to the
  user or unassigned — fetch `assignee`, compare with the user's identity; otherwise print the skip
  line). Already in Code Review / QA / Done → no-op. Transition id = profile `jira_transition_codereview`
  (MCP numeric id; the CLI state name may carry a suffix). Bugs created from `/triage` are NOT
  transitioned — they are open work for whoever owns the app code.

## 7. Stop

Print the summary. Nothing else runs.

</process>

<output_format>
```
/log <slug>[:C<k>] — {REPO_NAME} tracker={jira|github|linear|none}
Dedupe: {0 matches | linked KEY-n | N candidates shown}
Draft: {Task|Story|Bug} "<summary>" → {created KEY-n via mcp|cli | written tickets/<slug>-ticket.md | skipped}
State: ticket: KEY-n written to tickets/<kind>--<slug>.md (id unchanged)
PR: {gh pr edit offered: yes/no | no PR yet}
Transition: {Code Review (id) | skipped: --no-transition | skipped: assignee is <name> | n/a (bug) | no-op: already CR/QA/Done}
Next: /pr-creation if not opened yet; /triage or /cover continue on their own state files.
```
</output_format>

<guidelines>
- One AskUserQuestion decides creation; no draft is ever submitted on the model's own judgement.
- Drafts are plain language; nothing a non-engineer could not read. Code paths and selectors stay in
  the state file.
- `ticket:` is written into the existing file; the file is never renamed or moved.
- Transitions pass the assignee gate, respect `--no-transition`, and skip CR/QA/Done; bugs are not
  transitioned.
- `tracker_system: none` is a first-class path, not an error.
- Aliases only (`PROJ-XXXX`, `web-app`); never real keys or names in shared files.
</guidelines>

<success_criteria>
- [ ] State file resolved by slug, `--bug` ref, or branch; existing `ticket:` detected before drafting
- [ ] Dedupe attempted (agent, MCP, CLI) or explicitly reported as skipped
- [ ] Draft shown and approved via AskUserQuestion before any create call
- [ ] Record created through MCP → CLI → local-file fallback in that order; the key recorded
- [ ] `ticket: KEY-n` written into the SAME state file; no rename; event logged
- [ ] `--bug`: key written into the cluster row and the `test.fail` annotation where quarantined
- [ ] PR retitle offered when a PR exists; transition only through the assignee gate and never for bugs
- [ ] Stopped after the summary
</success_criteria>
