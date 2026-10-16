---
name: memory-lint
version: 0.10.3
description: Audit the auto-memory directory for drift — orphan files, broken pointers, schema violations, stale references. Reports only; no auto-fix without --fix flag + per-category confirmation.
argument-hint: "[--fix]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---
> **Model floor: sonnet** — audits memory files mechanically. This is guidance, not a pin: the command inherits the session model. Opus adds nothing here; Sonnet keeps its full power.

<objective>
Ingest, query, and lint are the three operations of a healthy LLM wiki (Karpathy pattern). This workflow has ingest (memory auto-saves during conversations) and query (MEMORY.md auto-loads into context), but no lint — until now. This command surfaces memory drift proactively, so stale claims don't get discovered when acting on them.

Reports only. Never deletes or edits memory without explicit per-category approval. Honors the "never delete memory without confirmation" rule (`feedback_never_delete_state_files.md`).
</objective>

<process>

## 0. Locate memory directory

```bash
# Auto-memory lives under ~/.claude/projects/<project-slug>/memory,
# where <project-slug> is your workspace path with "/" replaced by "-".
MEM_DIR="$HOME/.claude/projects/<project-slug>/memory"
INDEX="$MEM_DIR/MEMORY.md"
[ -d "$MEM_DIR" ] || { echo "Memory directory not found at $MEM_DIR"; exit 1; }
[ -f "$INDEX" ] || { echo "MEMORY.md missing — index is required"; exit 1; }
```

## 1. Orphan files

Any `*.md` in the memory dir not referenced by a link in `MEMORY.md`.

```bash
# Files on disk (exclude MEMORY.md itself)
disk_files=$(find "$MEM_DIR" -maxdepth 1 -name "*.md" -not -name "MEMORY.md" -exec basename {} \;)

# Files referenced in MEMORY.md as markdown links: ](filename.md)
indexed=$(grep -oE '\]\([a-zA-Z0-9_.-]+\.md\)' "$INDEX" | sed 's/](\(.*\))/\1/' | sort -u)

# Diff
for f in $disk_files; do
  echo "$indexed" | grep -qx "$f" || echo "ORPHAN: $f"
done
```

## 2. Broken pointers

Every link in MEMORY.md must resolve to an existing file.

```bash
for link in $indexed; do
  [ -f "$MEM_DIR/$link" ] || echo "BROKEN POINTER: MEMORY.md links to $link — file does not exist"
done
```

## 3. Schema violations

Every memory file (except MEMORY.md) must have frontmatter with `name`, `description`, and a `type`. `type` must be one of: `user | feedback | project | reference`. MEMORY.md MUST NOT have frontmatter (it's an index).

**Two frontmatter schemas are both valid** (the dir has drifted across two conventions):
- **Legacy:** `type:` at the top level of the frontmatter.
- **Current (canonical):** `type:` nested under a `metadata:` block (alongside `node_type`, `originSessionId`). This is the shape the memory-system spec emits today.

`name` and `description` are always top-level in both. Only `type` moved. The check below must accept either placement — an anchored `grep "^type:"` produces a false "missing field: type" on every current-schema file.

```bash
for f in $(find "$MEM_DIR" -maxdepth 1 -name "*.md" -not -name "MEMORY.md"); do
  fn=$(basename "$f")
  # Has frontmatter?
  head -1 "$f" | grep -q "^---$" || { echo "SCHEMA: $fn — missing frontmatter"; continue; }

  fm=$(awk 'BEGIN{c=0} /^---$/{c++; next} c==1{print} c==2{exit}' "$f")

  # name + description are always top-level
  for field in name description; do
    echo "$fm" | grep -q "^$field:" || echo "SCHEMA: $fn — missing field: $field"
  done

  # type lives EITHER top-level (legacy) OR nested under `metadata:` (current).
  # awk strips leading whitespace, so `$1 == "type:"` matches both `type:` and `  type:`.
  type_val=$(echo "$fm" | awk '$1 == "type:" { print $2 }' | tr -d '"')
  case "$type_val" in
    user|feedback|project|reference) ;;
    "")  echo "SCHEMA: $fn — missing field: type (checked top-level and nested under metadata:)" ;;
    *)   echo "SCHEMA: $fn — invalid type '$type_val' (must be user|feedback|project|reference)" ;;
  esac
done

# MEMORY.md must NOT have frontmatter
head -1 "$INDEX" | grep -q "^---$" && echo "SCHEMA: MEMORY.md has frontmatter — should be plain markdown (it's an index, not a memory)"
```

## 4. Stale file-path references

Each memory file may claim a path on disk. Test absolute paths that start with known prefixes (`/Users/`, `/opt/`, `/tmp/`, `/home/`). Skip templates with uppercase placeholders (`PROJ-XXXX`, `PROJ-XXX`) and single-segment paths like `/test.js`.

```bash
for f in $(find "$MEM_DIR" -maxdepth 1 -name "*.md"); do
  fn=$(basename "$f")
  grep -oE '/(Users|opt|tmp|home)/[a-zA-Z0-9_./-]+\.(md|yaml|yml|json|sh|ts|tsx|js|py|go|java|swift)\b' "$f" \
    | grep -vE 'PROJ-XXXX|PROJ-XXX|PROJ-[A-Z]+|[A-Z]{3,}-XXX' \
    | sort -u \
    | while read path; do
        [ -e "$path" ] || echo "STALE PATH: $fn references $path — path does not exist"
      done
done
```

Rationale: the earlier broad `/[a-z0-9_-/]+\.md` regex produced ~8 false positives from template patterns (e.g. `/tickets/PROJ-XXXX.md` is an illustrative placeholder, not a real path). Requiring a known prefix removes 90%+ of noise.

## 5. Stale command references

Any memory mentioning a `` `/command-name` `` (inside backticks — the markdown convention for command references) that's not in `.claude/commands/`. Backticks are the differentiator: they reliably mark intentional command citations and exclude URL-path segments like `/auth`, `/tests`, `/atoms`.

```bash
CMDS_DIR="$CLAUDE_PROJECT_DIR/.claude/commands"  # workspace-root commands dir
existing=$(find "$CMDS_DIR" -maxdepth 1 -name "*.md" -not -name "README.md" -exec basename {} .md \; | sort -u)

for f in $(find "$MEM_DIR" -maxdepth 1 -name "*.md"); do
  fn=$(basename "$f")
  # Match `/name` or `/name ` (followed by backtick or space) — true command citations.
  # The trailing [\` ] excludes URL paths like `/usr/local/...` or `/api/positions`
  # where the name is followed by another /.
  grep -oE '`/[a-z][a-z0-9-]+[` ]' "$f" \
    | sed -E 's/^`//; s/[` ]$//' \
    | sort -u \
    | while read cmdref; do
        name="${cmdref#/}"
        echo "$existing" | grep -qx "$name" || echo "STALE CMD: $fn references \`$cmdref\` — command no longer exists at workspace root"
      done
done
```

Rationale: `/security` and `/test` now resolve to built-in Claude Code skills, NOT custom commands. Backticked mentions in memory may still be valid if they refer to the built-in skill — this check flags them for human review, not auto-removal. The earlier broad regex without the backtick requirement produced 90+ false positives.

## 6. Past-dated project memories

`project_*.md` files that reference a date older than 30 days.

```bash
CUTOFF=$(date -u -v-30d +%Y-%m-%d 2>/dev/null || date -u -d "30 days ago" +%Y-%m-%d)

for f in "$MEM_DIR"/project_*.md; do
  [ -f "$f" ] || continue
  fn=$(basename "$f")
  last_date=$(head -20 "$f" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -r | head -1)
  [ -z "$last_date" ] && continue
  [[ "$last_date" < "$CUTOFF" ]] && echo "STALE PROJECT: $fn — most recent date $last_date (>30 days old)"
done
```

## 7. MEMORY.md length

System prompt hard-truncates MEMORY.md at 200 lines. Warn above 180.

```bash
lines=$(wc -l < "$INDEX" | tr -d ' ')
if [ "$lines" -gt 200 ]; then
  echo "LENGTH: MEMORY.md is $lines lines — HARD TRUNCATED at 200 in system prompt"
elif [ "$lines" -gt 180 ]; then
  echo "LENGTH: MEMORY.md is $lines lines — approaching 200-line cap"
fi
```

## 8. Report

Group findings by category. One block per non-empty category. Show counts. End each with a suggested action.

```markdown
## Memory Lint Report

### Orphans ({N})
- feedback_foo.md
- project_bar.md
→ Not indexed in MEMORY.md. Add a pointer under the right section, or consider archiving (never delete without review).

### Broken pointers ({N})
- MEMORY.md links to deleted_feedback.md — file does not exist
→ Remove the line from MEMORY.md (safe — the file it pointed to is already gone).

### Schema violations ({N})
- feedback_foo.md — missing field: description
- feedback_bar.md — invalid type 'xxx' (must be user|feedback|project|reference)
→ Add the four required frontmatter fields (name, description, type) per the schema.

### Stale paths ({N})
- feedback_xyz.md references /path/to/old/file — does not exist
→ Update the path to current location, or replace with historical-context wording.

### Stale command refs ({N})
- feedback_abc.md references /pre-flight — deleted 2026-04-22
- user_dep.md references /test — now a built-in skill, not a custom command
→ Update wording to match the current command surface, or note as historical.

### Stale project memories ({N})
- project_sprint_board_2026_03_26.md (last date: 2026-03-26, 27+ days old)
→ Refresh with current sprint state, OR add a "last verified: YYYY-MM-DD" line and keep as historical context. Do NOT delete without review.

### MEMORY.md length
- Lines: {N} / 200
→ {OK | approaching cap | truncated — trim one-liners or merge entries}

---
**Summary:** {T} findings across {C} categories. Run `/memory-lint --fix` to apply safe auto-fixes (orphans and broken pointers only, per-category confirmation).
```

## 9. `--fix` mode (optional)

If `$ARGUMENTS` contains `--fix`, after the report offer per-category actions. Never proceed without explicit per-category `yes`.

**Safe auto-fixes:**

a. **Orphans** → ask: "Add {N} orphan files to MEMORY.md under an '## Uncategorized (needs sorting)' section? (yes/no/review)"
   - `yes` → append the links to MEMORY.md under that heading
   - `review` → print the proposed diff and ask again
   - `no` → skip

b. **Broken pointers** → ask: "Remove {N} broken pointer lines from MEMORY.md? (yes/no/review)"
   - `yes` → delete the matching lines
   - `review` → print the diff
   - `no` → skip

**Never auto-fixed (needs human judgment):**
- Schema violations — the user knows what the right frontmatter values are
- Stale paths — may be intentional historical references
- Stale command refs — may be intentional historical references
- Stale project memories — protected by `feedback_never_delete_state_files.md`
- MEMORY.md length — requires editorial decisions

</process>

<success_criteria>
- [ ] Reads MEMORY.md and all *.md files in the memory dir
- [ ] Outputs findings grouped by 7 categories (only shows non-empty ones)
- [ ] Counts + per-category suggested action included
- [ ] `--fix` mode never proceeds without per-category confirmation
- [ ] No memory file deleted or modified without explicit user approval
- [ ] Safe to run as dry-run every session (read-only without `--fix`)
</success_criteria>

## Related Commands
- **Philosophically related:** Karpathy's LLM-wiki "ingest / query / lint" pattern. We have ingest + query; this closes the loop.
- **Consumes:** `MEMORY.md`, memory/*.md files, `.claude/commands/*.md` (for stale-command detection).
- **Consider auto-invoking from `/retro`** so drift gets caught weekly without requiring manual cadence. Same lesson as `/pre-flight`: a ceremony command that depends on human memory to invoke will rot.
