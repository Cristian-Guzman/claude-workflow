---
name: update
version: 0.9.0
model: "opus[1m]"
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

<objective>
`git pull` in the upstream clone tells you nothing about what changed for THIS install, and
`install.sh` overwrites every core file blind. `/update` is the installed side of versioning: what's
new since my version, what I edited locally that the update would clobber, what new config keys my
project-owned files are missing — then the install, with my edits carried over.
</objective>

<principles>
1. **Drift before copy.** Local edits to core files are found and dealt with before a single file is
   overwritten. They are either harvested (`/upstream`) or re-applied by 3-way merge against the
   install baseline. Losing them silently is the failure this command exists to prevent.
2. **Project-owned files are never overwritten.** New template keys are listed for the user to merge;
   the command may offer the exact snippet, never the write.
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
`drift` run — which is exactly right: they are still local edits.) Then run `/bootstrap` for gate flips
introduced by the new inventory, and print the template-merge list again as the to-do.

## 6. Stop
"Updated {old} → {new}. Kept {n} local edits ({k} conflicts to resolve). Merge by hand: {list}."

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
- [ ] After install, kept edits were re-applied by 3-way and conflicts named, not auto-resolved.
- [ ] `/bootstrap` ran afterwards (or was offered on `--dry-run`).
</success_criteria>
