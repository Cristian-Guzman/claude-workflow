---
name: bootstrap
version: 0.11.0
description: Adapt an installed workflow to THIS project. Runs the capability probe, evaluates every command's gate from inventory.yaml for the installed roles, and proposes keep / prune / un-archive — then writes only the capability manifest and the archive moves. Never writes command files (install.sh owns every file) and never manages versions (scripts/release.py, maintainer side).
argument-hint: "[--root <path>] [--dry-run]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Write
  - AskUserQuestion
---
> **Model floor: sonnet** — orchestrates probe + adapt-plan scripts. This is guidance, not a pin: the command inherits the session model. Opus adds nothing here; Sonnet keeps its full power.

<objective>
`install.sh` copies the workflow; `/bootstrap` fits it. Same install, different project → different
command set: a backend service has no `/qa`, a solo project has no `/demo-summary`, a repo with no
tracker runs `/build` instead of `/ticket`. This command decides that fit from evidence — a probe
script, not prose — shows the decision, and applies only reversible moves. Everything else that used
to live here is somewhere better: file writing in `install.sh` + `templates/`, versioning in
`scripts/release.py`, updates in `/update`.
</objective>

<principles>
1. **Evidence from a script, questions for the rest.** `capability-probe.sh` emits the vector; a `"?"`
   is one targeted question to the user, never a default. A wrong default silently installs or
   prunes the wrong commands.
2. **Writes are reversible and few.** Archive to `_archived-commands/`, un-archive from it, write
   `capability-manifest.md`. Nothing else. A gated-true command that is missing is reported with the
   installer command to run — this command does not create files.
3. **Usage beats the probe.** A command with state entries or artifacts is never pruned, whatever the
   gate says — the mismatch is reported so the profile or probe gets fixed. File age is not evidence:
   on a fresh install everything is new, and the first run is exactly when pruning matters.
4. **Core is never pruned.** Rows with `gate: always` and priority `core` stay, whatever the probe says.
5. **Plan first, then approval, then moves.** Pruning is a removal even when reversible.
6. **A file this project created is project-owned: never moved, never relabelled as retired.** A
   command, agent or script with no inventory row AND no copy in `.upstream-base/` was created here
   (LOCAL) — `install.sh` and `/bootstrap` never touch it. Only a file the baseline proves was
   upstream's can be called retired (ORPHAN).
</principles>

<process>

## 0. Resolve roots
`WORKSPACE_ROOT` = `--root` → `$WORKSPACE_ROOT` → `$CLAUDE_PROJECT_DIR` → CWD (same order as the guard
hook). `CLAUDE_DIR=$WORKSPACE_ROOT/.claude`. If `CLAUDE_DIR/commands/` is missing → stop:
"Nothing installed here. Run `install.sh <path> --role <r>` first; `/bootstrap` adapts, it does not install."

## 1. Probe
```bash
VEC=$("$CLAUDE_DIR/scripts/capability-probe.sh" "$WORKSPACE_ROOT"); rc=$?
```
Parse the JSON. For every value equal to `"?"` (rc 3), ask ONE AskUserQuestion naming the signal and
the options the inventory gates on (e.g. ticket_system: jira / github / linear / none). Record the
answer into the vector. Show the resolved vector.

## 2. Load the inventory for the installed roles
Read `CLAUDE_DIR/inventory.yaml` (installed from `core/docs/`). Keep rows whose `role` is `core` or
in the vector's `roles[]`. If `roles[]` is empty (pre-0.8.0 install), infer from the files present per
role directory the way `install.sh` does, and say so.

## 3. Evaluate gates → decisions
For each kept row, evaluate `gate` against the vector (grammar: `always`, `cap == v`, `cap != v`,
`cap >= n`, `AND`, `OR`, parentheses; `ui_surfaces` is a comma list, `!= none` means non-empty).
Run it, don't re-derive it: `python3 "$CLAUDE_DIR/scripts/adapt-plan.py" --root "$CLAUDE_DIR" --vector "$TMP/vector.json"
--json` evaluates every gate against the vector and the file states and returns the decision table below
(exit 3 if the vector still carries a `?`). The command's job is to show it, ask, and move files.

| File state | Gate | Decision |
|---|---|---|
| in `commands/` | true | **KEEP** |
| in `commands/` | false | **PRUNE** → unless `priority: core AND gate: always` (**KEEP(core)**), or usage evidence exists (`state/index.json` entry naming it, or its artifact dir is non-empty) → **KEEP(in-use)** with "gate false but used — fix the profile/probe" |
| in `_archived-commands/` | true | **UN-ARCHIVE** |
| in `_archived-commands/` | false | leave |
| missing from both | true | **MISSING** → report `install.sh <root> --role <role>`; write nothing |
| missing from both | false | ignore |
| in `commands/` or `agents/`, **no inventory row**, and not project-owned | — | **ORPHAN** → report only, never moved. `install.sh` already archives a retired file it can prove was upstream's and unmodified; the reason says which of these remains: a **locally edited** retired file it kept (copy under `.upstream-prior/<date>/installed/<kind>/` — say where); a file **captured whole** on the first baselined install (copy under `.upstream-prior/<date>/<kind>/` — upstream's old copy or the project's own, nothing proven: compare, then archive or keep); a file **in the current baseline** with no row (upstream ships it, the inventory is missing a row — upstream drift, nothing to do here); or, with **no baseline** at all (< 0.7.0 install), a leftover nothing can vouch for. The owner archives by hand after a look |
| in `commands/`, `agents/` or `scripts/`, **no inventory row, not in `.upstream-base/`** (baseline exists) | — | **LOCAL** (project-owned) → reason "created in this project, never shipped upstream — install.sh and /bootstrap never touch it". Never moved, never called retired |
| **any** name that `workflow-manifest.json` `"conflicts"` lists as `<kind>/<name>` — with or without an inventory row (a collision can only involve a shipped file, and every shipped command/agent has a row, so this is the row that actually fires) | — | **CONFLICT** → reason "project-owned file with the same name as upstream's <kind>; install.sh kept yours and did not install upstream's — rename yours to adopt upstream's, or keep ignoring it". Takes precedence over the gate: never KEEP/PRUNE a file upstream's gate describes but that isn't upstream's. Never moved |

Agents follow the same table against the `agents:` rows. `scripts/` has no inventory rows, so a script
is only ever LOCAL or CONFLICT — never ORPHAN, never moved.
Diff against the previous `capability-manifest.md` when present: only decisions that FLIPPED since the
last run are shown as changes; unchanged ones are summarized in one line.

## 4. Present and wait
```
# Bootstrap plan — {WORKSPACE_ROOT}
Roles: {roles} · vector: {vcs_host, ci, ticket_system, ui_surfaces, e2e, repo_count, team, memory_system}
KEEP {n} · PRUNE {n} · UN-ARCHIVE {n} · MISSING {n} · ORPHAN {n} · LOCAL {n} · CONFLICT {n} · unchanged since last run {n}
| Command | Role | Gate | Decision | Reason |
```
`--dry-run` stops here. Otherwise AskUserQuestion: apply / apply without prunes / cancel.

## 5. Apply
- PRUNE: `mv commands/<c>.md _archived-commands/<c>.md` (never `rm`). Same for agents under `agents/`.
- UN-ARCHIVE: the reverse move.
- Only PRUNE and UN-ARCHIVE rows move. **LOCAL and CONFLICT rows are never moved, archived or
  renamed by this command** — they are the project's own files; a CONFLICT is resolved by the owner
  renaming their file (or leaving it), nothing else. ORPHAN rows are reported only, never moved.
- Write `CLAUDE_DIR/capability-manifest.md`: date, roles, the vector, one row per command with
  decision + reason + the gate text, and the un-archive instruction. This file is the audit trail the
  next run diffs against.

## 6. Summary
Counts per decision, the manifest path, and — for any MISSING row — the exact installer command.
List the LOCAL files in one line ("project-owned, left alone: …") and each CONFLICT with its rename
advice.
Suggest `/update` when the manifest's installed version is older than the inventory's newest `since`.
Print the **model floors** of the kept commands (from `inventory.yaml` `floor:`), grouped `opus` / `sonnet`, with the one-line reminder that nothing is pinned and the sonnet group keeps its full power on Sonnet.

</process>

<guidelines>
- Read-only on everything except `commands/`, `agents/`, `_archived-commands/`, and the manifest.
- No version logic here. `scripts/release.py` (maintainer) and `/update` (installed side) own it.
- No inline templates, no command specs. If a file is missing, the installer is the answer.
- Gate evaluation is literal; if a gate does not parse, treat the row as KEEP and report the parse
  error — never prune on a broken expression.
- Related: `install.sh` (writes files), `/update` (brings a newer upstream in), `/upstream` (sends
  learnings out), `core/docs/inventory.yaml` (the gates).
</guidelines>

<success_criteria>
- [ ] Every `"?"` in the probe output became a question, never a default.
- [ ] No command file was created or edited; only moves between `commands/` and `_archived-commands/`.
- [ ] No `priority: core` + `gate: always` row was pruned; nothing with usage evidence was pruned.
- [ ] No LOCAL or CONFLICT file was moved, archived or labelled retired; every one was listed.
- [ ] `capability-manifest.md` written with vector, roles, and a reason per row.
- [ ] Re-running immediately reports zero flipped decisions.
</success_criteria>
