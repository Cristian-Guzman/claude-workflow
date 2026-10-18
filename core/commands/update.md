---
name: update
version: 0.11.0
description: Bring an installed workflow up to the newest upstream version without losing local edits. Shows only the changelog entries you don't have, surfaces local edits to core files BEFORE anything is overwritten (harvest them with /upstream or keep them via 3-way merge), lists new keys in project-owned templates to merge by hand, then runs install.sh and re-runs /bootstrap for gate flips.
argument-hint: "[--check] [--upstream <path-or-owner/repo>] [--dry-run]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Write
  - Edit
  - AskUserQuestion
---
> **Model floor: sonnet** — orchestrates drift + install scripts. This is guidance, not a pin: the command inherits the session model. Opus adds nothing here; Sonnet keeps its full power.

<objective>
`git pull` in the upstream clone tells you nothing about what changed for THIS install. `/update` is
the installed side of versioning, and it states the installer's contract before running it:
**core files** (everything the previous `.upstream-base/` snapshot lists) are refreshed, with local
edits captured to `.upstream-prior/<date>/` and re-applied by 3-way merge; **project-owned
commands, agents and scripts** (under `.claude/{commands,agents,scripts}` but NOT in that snapshot —
a step this project invented) are never overwritten or archived, and are listed so you can see they
were left alone; a **same-name arrival** (upstream now ships a file with a project-owned basename)
is skipped — yours stays, upstream's copy is not installed — and reported as a conflict for you to
rename. So: what's new since my version, what I edited locally, what is mine and untouched, what
new config keys my project-owned templates are missing — then the install, with my edits carried over.
</objective>

<principles>
1. **Drift before copy.** Local edits to core files are found and dealt with before a single file is
   overwritten. They are either harvested (`/upstream`) or re-applied by 3-way merge against the
   install baseline. Losing them silently is the failure this command exists to prevent.
2. **Project-owned files are never overwritten.** New template keys are listed for the user to merge;
   the command may offer the exact snippet, never the write. The same holds for a command, agent or
   script the project created: `install.sh` leaves it in place, never archives it, and when upstream
   ships a file of the same name it keeps yours, skips upstream's and prints a `conflict` line —
   this command relays that list and never proposes archiving any of them.
3. **Show the delta, not the whole changelog.** Only entries newer than the installed version.
4. **The installer installs.** This command prepares, confirms, calls `install.sh`, re-applies, and
   re-adapts. It does not copy files itself.
</principles>

<process>

## 0. Where am I, what do I have
`WORKSPACE_ROOT` as in the guard hook. Read `CLAUDE_DIR/.upstream-manifest.json` → `version`,
`source_commit`, `upstream_repo`, `roles` (and `CLAUDE_DIR/workflow-manifest.json` for roles when the
upstream manifest predates them). Missing manifest → stop: "no install baseline; run `install.sh`
once (0.7.0+) to record one, then `/update`."

## 1. Where is upstream
`--upstream <path>` → a local clone (preferred: `git -C <path> fetch origin && git -C <path> rev-parse
origin/main`). Else `--upstream owner/repo` or the manifest's `upstream_repo` → read
`core/docs/workflow-version.md` with `gh api repos/<owner>/<repo>/contents/core/docs/workflow-version.md
-H "Accept: application/vnd.github.raw"`. Newest version = its frontmatter `version:`.
Equal to installed → "up to date ({version})" and stop (also the `--check` exit).

## 2. The delta
Print the changelog entries between installed and newest (parse `### X.Y.Z —` headings). Tag each
bullet that names a command the installed roles don't include as "(role not installed)".

## 3. Drift first
```bash
python3 "$CLAUDE_DIR/scripts/upstream.py" --root "$CLAUDE_DIR" drift --json --out "$TMP/drift"
```
For each `modified` core file:
- Offer **harvest** (`/upstream` would carry it; stop here if the user wants to harvest first), or
- **keep**: after the install, `git apply --3way` the diff from `$TMP/drift` onto the new file. Record
  the choice per file. Conflicts are shown and left to the user, never auto-resolved.
`missing` core files (deleted locally on purpose) → ask keep-deleted / restore.

## 3b. Project-owned commands, agents, scripts — what the install will leave alone
Project-owned = installed under `commands/`, `agents/`, `scripts/` (and `learn-targets/`) with no
copy in the CURRENT `.upstream-base/` — the snapshot the previous install wrote. Compute it BEFORE
the install (the install rewrites the snapshot):
```bash
for k in commands agents scripts learn-targets; do
  for f in "$CLAUDE_DIR/$k"/*; do [ -f "$f" ] || continue
    [ -f "$CLAUDE_DIR/.upstream-base/$k/$(basename "$f")" ] || echo "project-owned $k/$(basename "$f")"
  done
done
```
Print the list as "left alone (project-owned): …". For each, check whether a selected upstream source
(`<clone>/core/<k>/`, `<clone>/roles/<role>/<k>/`) ships the same basename — those will be reported
by `install.sh` as `conflict <kind>/<name> — project-owned … kept yours`; say so now, with the rename
advice. Never propose archiving a project-owned file. If `.upstream-base/` does not exist (a
pre-0.7.0 install) print one line: "no baseline — project-owned files cannot be told from upstream's;
install.sh captures everything it would overwrite to .upstream-prior/<date>/ first" and move on.

## 4. Project-owned files: what's new in the templates
For each `owner: project` row in `inventory.yaml` with a template in upstream (`templates/repo/*`,
`templates/workspace/*`, `repo-profiles/_schema.yaml`): diff the OLD template (from
`.upstream-base/` or the clone at `source_commit`) against the NEW template. New top-level keys or
`##` sections → list them with the snippet to paste. No writes.

## 5. Confirm, install, re-apply, re-adapt
AskUserQuestion with: versions, N files kept via 3-way, M harvested/deferred, K template keys to merge.
Then, unless `--dry-run`:
```bash
"<clone>/install.sh" "$WORKSPACE_ROOT" $(printf -- '--role %s ' $roles)
for d in "$TMP"/drift/*.diff; do git -C "$CLAUDE_DIR" apply --3way --directory=. "$d" || echo "CONFLICT $d"; done
```
(`install.sh` refreshes `.upstream-base/` to the NEW core, so the re-applied edits show up in the next
`drift` run — which is exactly right: they are still local edits.) Then, from the installer output and
`CLAUDE_DIR/workflow-manifest.json`, print the project-owned outcome: every `conflict …` line the
installer printed, plus the manifest's `"conflicts": ["<kind>/<name>", …]` (absent = none), each with
"kept yours; upstream's new <kind> of the same name was NOT installed — rename yours to adopt it".
Re-check the step-3b list still exists unchanged (`cmp` against a copy taken before the install — a
project-owned file that changed or vanished is a bug to report, not something to fix by hand). Then run
`/bootstrap` for gate flips introduced by the new inventory — it shows the same files as LOCAL /
CONFLICT and never moves them — and print the template-merge list again as the to-do.

## 6. Stop
"Updated {old} → {new}. Kept {n} local edits ({k} merge conflicts to resolve). Left alone: {p}
project-owned files. Same-name collisions: {c} (rename yours to adopt upstream's: {list}). Merge by
hand: {list}."

</process>

<guidelines>
- Never run on a dirty company workspace without showing drift first; never skip step 3 for speed.
- `--check` is read-only and cheap enough for a session start: installed vs newest, one line.
- Related: `install.sh`, `/bootstrap`, `/upstream`, `scripts/upstream.py drift`, `core/docs/inventory.yaml`.
</guidelines>

<success_criteria>
- [ ] Printed only the changelog entries newer than the installed version.
- [ ] Every locally modified core file was listed before any copy, with a per-file decision.
- [ ] No project-owned file was written; new template keys were listed with snippets.
- [ ] No project-owned command, agent or script was overwritten or archived; the list of those left
      alone and every same-name conflict (installer output + manifest `conflicts`) was printed, and
      none was proposed for archiving.
- [ ] After install, kept edits were re-applied by 3-way and conflicts named, not auto-resolved.
- [ ] `/bootstrap` ran afterwards (or was offered on `--dry-run`).
</success_criteria>
