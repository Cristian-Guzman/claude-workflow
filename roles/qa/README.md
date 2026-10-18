# Role: qa (manual QA)

The manual-testing lane. **No commands of its own**: it is a flow over the core set, plus the
knowledge files `/learn` grows for it. Install with `--role qa`; combine with `--roles dev,qa`
or `--roles sdet,qa` (a QA who also automates runs both lanes).

What a manual tester's week needs that the dev and sdet lanes don't give: a place where
**executed results** live so the rest of the system can read them, a path from a **failed step**
to a bug and to a root cause, and a **learning loop** over what bounces and what never does.
This folder supplies the first and the third as conventions and files; the second is the one
seam still done by hand (see "Deliberately not here").

## Pipeline

```
intake ──▶ plan ──▶ execute ──▶ close ──▶ learn
 /qa        (/verify)  you        you      /learn
```

| Case | Steps | Count |
|---|---|---|
| Test a ticket | `/qa PROJ-123` → execute → fill the sidecar → `/learn` | **2** commands |
| Test a dev branch you can check out | `/verify` → `/qa` → execute → sidecar → `/learn` | 3 — `/verify`'s UNVERIFIED rows are exactly the manual remainder |
| Requirements only (no ticket, no code) | `/qa` with the pasted requirements → execute → sidecar → `/learn` | 2 |
| Exploratory session | copy `qa-charter.md` → explore → findings become sidecar rows → `/learn` | 1 |
| Regression before a release | `/status` → re-run the sidecars whose rows found bugs (see `regression-map.md`) → `/learn` | 2 |
| A step fails and you can't name the cause | `/project-debug "<symptom>"` (the cause-known gate) → bug ticket by hand | 1 |

## Commands used (all core or shared — nothing new)

| Command | What it does for this role |
|---|---|
| `/qa` | Turns a ticket, a state file, or pasted requirements into a step-by-step guide with expected results, edge cases and the test data it needs. Backend tickets get a runtime-evidence guide (deploy check, trigger, inspect, logs). Writes `.claude/qa/<ticket>.md`. |
| `/verify` (dev role, when installed) | Run on the dev's branch BEFORE testing: machine-checkable gates get receipts, and every gate the machine cannot see is born **UNVERIFIED** with the human step that confirms it. Those rows are your manual plan; `/qa` expands them. Your `qa-confirmed` rows are what lift the dev's confidence cap. |
| `/project-debug` | A failed step whose cause you cannot name in one sentence. Captures symptom, hypotheses and what you ruled out in `.claude/debug/<slug>.md`; hands a known cause to the dev. |
| `/status` | What is in flight across repos, which sidecars are still `in-progress`, what bounced. |
| `/screenshot` | Evidence capture for a step, into the ticket's screenshot folder. |
| `/learn` | Reads delivered `qa` sidecars and grows `qa-ledger.md` and `regression-map.md` (targets below). Run it after every ticket; it is what makes the lane project-specific. |
| `/upstream` | Monthly: carries the generic lessons back to the workflow without any company data. |

## The hard rule: results are rows, and rows live in the sidecar

Every executed step gets **one row** in a sidecar at `.claude/tickets/qa--<key>.md` (`<key>` = the
ticket id, or a slug for requirements-only work). The `/qa` guide is the plan; the sidecar is the
record. Nothing else in the workflow reads a chat message or a spreadsheet.

```markdown
---
kind: qa                      # REQUIRED — what the state index keys on
key: PROJ-123                 # ticket id or slug
ticket: PROJ-123              # null for requirements-only work
area: checkout                # one word the ledger clusters on (route, feature, screen)
env: staging                  # where it ran
build: 1.42.0+abc123          # what ran (version, sha, or deploy id)
status: in-progress           # in-progress → delivered (+ bounced when a tester re-opens it)
created: 2026-10-18
updated: 2026-10-18
---

## QA Results
| # | Step | Expected | Result | Evidence | Bug |
|---|---|---|---|---|---|
| 1 | Open /checkout as a guest | Cart summary visible | pass | | |
| 2 | Apply an expired coupon | Inline error, total unchanged | **fail** | `screenshots/PROJ-123/02.png` | PROJ-140 |
| 3 | Pay with a declined card | Error, order not created | pass | | |

## Not covered
- Mobile Safari — no device this sprint (say so; never leave a row blank)

## Notes
- Step 2: the error appears, but the total updates first and flips back (flicker ~300 ms) — filed as PROJ-140
```

Rules:
- `Result` is `pass`, `fail`, `blocked`, or `skip` — never empty. A `fail` row carries an evidence
  path and, once filed, the bug key. A `blocked` row says what blocked it in `Notes`.
- `status: delivered` when every planned row has a result. `/learn` reads only delivered sidecars.
- When the dev's fix comes back, do **not** start a new sidecar: set `status: bounced` → re-run the
  failed rows → `delivered`. The bounce count is the signal `/learn` clusters on.
- Evidence goes to `.claude/screenshots/<key>/` (or the repo's screenshot folder); paths in rows
  are relative to `.claude/`.
- If `/verify` ran, copy its UNVERIFIED gate names as steps verbatim, and when a row passes append
  `- [HH:MM] qa-confirmed via manual: <gate name>` to the ticket's Event Log — that is the line the
  dev's `/verify` re-run reads to lift the 70% cap.

## Learn targets

`learn-targets.yaml` tells `/learn` to scan `kind: qa` sidecars with `status: delivered` and grow:

| File | What accumulates | Lesson at |
|---|---|---|
| `qa-ledger.md` | every `fail` and every bounce, keyed by `area` — "what bounces here and why" | 2 occurrences of the same area + failure class |
| `regression-map.md` | the steps whose rows found bugs (candidates for the regression set) and the steps that passed every run (candidates to drop) — log only, you decide | never promoted automatically |

`install.sh` copies the contract to `.claude/learn-targets/qa.yaml`.

## Seeds (`templates/repo/`, seeded once, never overwritten)

- `qa-ledger.md` — the ledger `/learn` writes into.
- `regression-map.md` — the found-bugs / never-fails map `/learn` logs into.
- `qa-charter.md` — an exploratory-session charter: scope, risks, time-box, notes, findings → sidecar rows.

Project-owned from the first install. The sidecar skeleton above is the template for results; copy it.

## Requirements intake

`/qa` takes pasted requirements when there is no ticket. Keep the source of truth local and
readable: export the page (Notion, Confluence, a doc) under `.claude/specs/<wiki>/<slug>.md` and
paste its acceptance statements into `/qa`. Each statement should be testable as written — "the
total updates within one second" is a step; "the UX should feel fast" is not, and `/qa` will ask.

## Deliberately not here

- **A command that turns a failed row into a bug ticket.** `/log` mints tickets from `/cover` and
  `/triage` state files only. For a failed manual row, file the bug by hand from the row (step,
  expected, actual, evidence path) and write its key into the `Bug` column. Teaching `/log` to read
  a `qa` sidecar is the obvious next seam, left until a month of sidecars shows the row shape holds.
- Test-case management, evidence tooling, device farms. The sidecar is deliberately a markdown
  table so it survives any tracker and any team size.

## Start here

`/qa <ticket>` → test → fill `tickets/qa--<ticket>.md` → `/learn`. Everything else above is reachable
from that loop.
