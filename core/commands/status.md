---
name: status
version: 0.10.0
description: Cross-repo work dashboard. Active tickets, open debug sessions, unresolved PRs, blocked items. Grouped by state, prioritized by recency.
argument-hint: "[--days N] [--repo NAME] [--all]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
---

<objective>
Replace mental tracking with a single scan. With 9+ repos in the workspace, a dump is useless — this command groups by state, prioritizes by recency, and surfaces only what's actionable.

Defaults to the last **7 days**. Collapses stale entries. Does not modify anything.
</objective>

<process>

## 1. Parse Arguments

- `--days N` — window size (default 7)
- `--repo NAME` — limit to one repo
- `--all` — ignore the window, show everything

## 2. Scan Every Repo — prefer state index, fall back to glob

### Fast path: read the state registry
```bash
INDEX=$WORKSPACE_ROOT/.claude/state/index.json
if [ -f "$INDEX" ]; then
  # Skip the 9-repo filesystem walk entirely — one jq read replaces it.
  # Filter by --days window and --repo argument if provided.
  CUTOFF=$(date -u -v-"${DAYS:-7}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "${DAYS:-7} days ago" +%Y-%m-%dT%H:%M:%SZ)
  jq --arg cutoff "$CUTOFF" --arg repo "${REPO_FILTER:-}" '
    .entries
    | map(select(.archived != true))
    | map(select($repo == "" or .repo == $repo))
    | map(select(.updated >= $cutoff or .status == "planning" or .status == "implementing" or .status == "pr-generated"))
  ' "$INDEX"
fi
```

Advantages: one file read vs 45 filesystem walks, consistent across commands, orphan-aware.

**Staleness check:** if `index.json`'s `generated` field is >24h old, run a silent `state-index-scan.sh --verify` in the background before using the output. If >7d old, warn the user and recommend `state-index-scan.sh --bootstrap`.

### Fallback: direct repo scan (only when index is missing or corrupt)

If `index.json` doesn't exist or `jq` fails, fall back to the old glob:

```bash
# Kind directories come from the schema's enum line, not a hardcoded list (state-file-schema.md → Kinds).
KIND_DIRS=$(sed -n 's/^<!-- kind-dirs: \(.*\) -->$/\1/p' "$WORKSPACE_ROOT/.claude/state-file-schema.md" 2>/dev/null)
: "${KIND_DIRS:=tickets debug builds refactors e2e}"   # schema doc absent → last known list
for dir in "$WORKSPACE_ROOT"/*/; do
  repo=$(basename "$dir")
  for kind in $KIND_DIRS; do
    for f in "$dir.claude/$kind/"*.md; do
      [ -f "$f" ] || continue
      status=$(awk '/^status:/{print $2; exit}' "$f")
      updated=$(awk '/^updated:/{print $2; exit}' "$f")
      echo "$repo|$kind|$(basename $f .md)|$status|$updated"
    done
  done
done 2>/dev/null
```

After fallback, suggest: "State registry missing — run `state-index-scan.sh --bootstrap` to enable O(1) status lookups."

### Open PRs (requires gh CLI auth)
```bash
for dir in "$WORKSPACE_ROOT"/*/; do
  [ -d "$dir/.git" ] || continue
  gh -R "$(git -C "$dir" remote get-url origin 2>/dev/null | sed -E 's#.*[:/]([^/]+/[^/.]+)(\.git)?#\1#')" pr list --state open --author "@me" --json number,title,headRefName,updatedAt,reviewDecision 2>/dev/null
done
```

### Current branch + uncommitted changes
```bash
for dir in "$WORKSPACE_ROOT"/*/; do
  [ -d "$dir/.git" ] || continue
  branch=$(git -C "$dir" branch --show-current)
  dirty=$(git -C "$dir" status --porcelain | wc -l | tr -d ' ')
  echo "$(basename $dir)|$branch|$dirty"
done
```

## 3. Group and Filter

Buckets:

1. **In flight** — state file status is `planning`, `implementing`, `testing`, `investigating`, or `debugging` AND `updated:` within the window
2. **Waiting on review** — PR status is `open` AND author is you AND `reviewDecision` is null or `REVIEW_REQUIRED`
3. **Waiting on merge** — state file status is `delivered` OR PR has `APPROVED` review
4. **Blocked / stale** — state file or PR hasn't been updated in ≥`days` days. Collapse under a single "Stale (click to expand)" header
5. **Uncommitted work** — repos where `git status --porcelain` has entries

## 4. Cross-repo epic view

Read `$WORKSPACE_ROOT/.claude/project-map.md` (if it exists) to surface shared topics:

```markdown
## Cross-repo work
Epic A → addin-fe (2 active), api-bff (1 active), backend-services (0 active)
Billing changes → billing-service (1 active), api-bff (1 related)
```

If `project-map.md` doesn't exist, skip this section and suggest: "Run `/project-context` to enable cross-repo epic tracking."

## 5. Output

```markdown
# Work Status — {today} (last {N} days)

## 🔄 In Flight
| Repo | Kind | ID | Status | Last updated | Current focus |
|------|------|----|--------|--------------|---------------|
| api-bff | ticket | [[PROJ-5901]] | implementing | 2h ago | Add snake_case mapper |
| addin-fe | debug | formataction-crash | investigating | 1d ago | Testing hypothesis 3 |

## 👀 Waiting on Review
| Repo | PR | Title | Age | Reviewers |
|------|----|-------|-----|-----------|
| addin-fe | #183 | [[PROJ-5878]] dark-mode contrast | 2d | @reviewer1 (requested) |

## ✅ Waiting on Merge
| Repo | PR | Title | Approved? |
|------|----|-------|-----------|
| addin-fe | #181 | [[PROJ-5835]] trial banner | yes (2d ago) |

## 📝 Uncommitted
| Repo | Branch | Changes |
|------|--------|---------|
| addin-fe | feat/[[PROJ-5878]]-dark-mode | 3 files |

## ⚠ Stale (>{N} days — consider archiving)
- ios-app / [[PROJ-5579]] (12d old, status: planning)

## 🔗 Cross-Repo
Epic A → addin-fe (2), api-bff (1)

## Suggested next actions
1. Finish [[PROJ-5901]] implementation (top-of-list by recency)
2. Address review on PR #183 (oldest unreviewed)
3. Commit the work on feat/[[PROJ-5878]]-dark-mode (avoid loss)
4. Archive or resume [[PROJ-5579]] (12 days stale)
```

Show buckets only if non-empty. Keep tables wide enough to be readable, short enough to scan in 10 seconds.

</process>

<success_criteria>
- [ ] All 9+ repos scanned
- [ ] Groupings respect the --days window
- [ ] Stale items collapsed, not hidden
- [ ] Cross-repo epic view rendered when `project-map.md` exists
- [ ] Suggested next actions appear at the end
- [ ] No file written, no git state changed
</success_criteria>

## Related Commands
- Inputs: state files, open PRs, `project-map.md`
- Typical follow-ups: `/resume-ticket` (pick up in-flight work), `/review-comments` (triage review feedback), `/pr-creation` (push delivered work)
