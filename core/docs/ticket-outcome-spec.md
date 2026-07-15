<!-- last-updated: 2026-06-15 -->
# Ticket Outcome + Health — shared derivation spec

Canonical, single-source definition of how a ticket's **Outcome** (status timeline, QA bounces, cycle time) and **Health** (difficulty band) are computed from Jira + git + GitHub. Two commands cite this so the math never drifts between them:

- **`/project-context` Step 7** — applies it to **teammates'** tickets → `.claude/team-tickets/PROJ-XXXX.md` dossiers.
- **`/learn` §5** — applies it to **your own** tickets → an `AUTO:CLOSEOUT` region in `{repo}/.claude/tickets/PROJ-XXXX.md`.

**The only difference between the two callers is CONFIDENCE, not coverage:**
- **Own tickets are FIRSTHAND** — you (and Claude, in-session) have direct context, so the Closeout's lessons may **state cause directly**.
- **Teammate tickets are INFERRED** — no firsthand context, so the dossier's lessons must be prefixed **`⚠ inferred — verify`**.

Everything below is identical for both.

## Outcome

**Status timeline + QA bounces** — the strongest, least-gameable difficulty signal. The `jira` CLI can't expose changelog; use REST:
```bash
AUTH=$(jira issue view PROJ-XXXX --debug 2>&1 | grep -m1 'Authorization:' | sed 's/.*Authorization: //')
[ -z "$AUTH" ] && echo "Jira auth not found in --debug output — skip the Outcome sub-step for this run" >&2
curl -s -H "Authorization: $AUTH" -H 'Accept: application/json' \
  "https://your-org.atlassian.net/rest/api/3/issue/PROJ-XXXX?expand=changelog&fields=status"
```
Parse `changelog.histories[].items[]` where `field == 'status'` → ordered `fromString → toString` timeline.
- **`qa_bounces` = (count of transitions whose `toString == 'QA'`) − 1.** Entering QA more than once = it got kicked back. `0` = clean.
- Project states: To Do → In Progress → Code Review → QA → Done (your Jira instance may suffix state names — e.g. a code-review state literally named `Code Review (1)` — check the CLI's exact name).

**Cycle time** — from the ticket's **first commit** (preferred; fall back to the `In Progress` transition if no commit is attributable) to `Done` — **NOT Jira `created`** (backlog age ≠ difficulty, and would wrongly inflate a healthy ticket that sat in the backlog). Story points = your instance's story-points custom field (e.g. `customfield_10080` — look it up per-instance; null if unestimated).

### `outcome:` frontmatter contract (ci-check → learn)

`/ci-check` snapshots the cheap, changelog-derived fields at merge so they survive a skipped retro; `/learn` seeds the Closeout from them and derives the rest:
```yaml
outcome:
  merged_at: <ISO8601>
  jira_status: <status at merge>
  qa_bounces: <int>
  timeline: "<status → status → …>"
```
Cycle time + story points are **not** snapshotted (cheap to derive at Closeout time) — `/learn` computes them if absent.

## Health score (rate the work, never the person)

Transparent, auditable, **normalized by repo + kind** so the team's intentional micro-commit/micro-PR UI workflow isn't read as struggle. Additive points → band:

- **QA bounces** — `+3` each. *Strongest, outcome-based, not gameable.*
- **`CHANGES_REQUESTED`** on any PR — `+2`. (`reviewDecision` is a single terminal value and the org uses neither inline comments nor multi-round reviews — do **not** try to count review rounds; there's no data source for it.)
- **Backend multi-PR** — in `backend-services`/`api-bff` only, `+1` per PR beyond the 2nd. **FE/Add-in repos contribute 0 multi-PR points** (micro-PR is the norm there).
- **Cycle time** — `+1` if > 2×, `+2` if > 4× the **window's median days-per-story-point** (self-calibrating). **Window-only:** this points component applies to the windowed caller (`/project-context`) only; a single own-ticket Closeout records cycle time as a *fact* but adds no cycle points (it has no window median to compare against). Skip if unestimated or not yet Done. (This is the sole component that differs between the two callers — every other signal scores identically.)
- **closed-unmerged (non-superseded)** — `+1`; skip superseded micro-PRs in Add-in/FE repos.
- **Author count ≥3** — `+1` as a coordination *note* (flag, not blame).
- **Cross-repo** — `0` points; context only (one logical ticket spanning repos legitimately needs one PR per repo).

**Bands:** `0–1 = 🟢 healthy`, `2–4 = 🟠 watch`, `≥5 = 🔴 rough`. The "why" line must name the signals that scored — e.g. `🔴 2 QA bounces + CHANGES_REQUESTED on backend-services#159`.

**When a lessons/auto-observation line fires:** only on a strong signal — `qa_bounces ≥ 2`, any `CHANGES_REQUESTED`, or backend multi-PR. No strong signal → facts only, no observation. (Teammate dossiers prefix the observation `⚠ inferred — verify`; own Closeouts state cause directly.)

## Worked example (reproduces under the rules above)

Timeline `To Do → In Progress → Code Review → QA → Code Review → QA` = entered QA 2× → `qa_bounces: 1` → `+3`. One PR had `CHANGES_REQUESTED` → `+2`. Multi-PR not penalized (FE norm). **Score 5 → 🔴 rough.**

## Callers

| | `/project-context` Step 7 (teammate) | `/learn` §5 (own) |
|---|---|---|
| Artifact | `.claude/team-tickets/PROJ-XXXX.md` (new file) | a `## Closeout` section wrapping an `AUTO:CLOSEOUT` region, in the existing state file |
| Regen region | `<!-- AUTO:FACTS START/END -->` | `<!-- AUTO:CLOSEOUT START/END -->` |
| Human half | `## Notes (human)` | the existing `## Retrospective` |
| Lessons confidence | `⚠ inferred — verify` | firsthand — state cause directly |
| Activity window | sprint-windowed (default 14d) | the single ticket |
