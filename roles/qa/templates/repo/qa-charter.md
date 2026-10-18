<!--
  qa-charter.md — an exploratory-session charter. Copy it per session (e.g. to
  .claude/tickets/qa--explore-<slug>.md with `kind: qa` frontmatter so /learn can read the rows),
  time-box it, and turn every finding into a results row. Project-owned: seeded once.
-->

# Charter: {area} — {one line: what you are trying to break}

- **Scope:** {screens / routes / flows in; what is explicitly out}
- **Risks to probe:** {what changed recently, what has bounced before (see qa-ledger.md), what the dev said was tricky}
- **Oracles:** {how you know it is wrong — spec, previous build, a sibling surface, an invariant}
- **Data / accounts:** {roles, states, edge data you need ready before starting}
- **Time-box:** {45–90 min}; **env:** {staging}; **build:** {version/sha}

## Tours (pick 2–3)
- Boundary: smallest / largest / empty / one-over
- Interruption: refresh, back, offline, double-submit, slow network
- Role: the same flow as each role that can reach it
- State: start mid-flow, revisit after completion, concurrent edit

## Notes (timestamped, as you go)
- HH:MM —

## Findings → sidecar rows
| # | Step | Expected | Result | Evidence | Bug |
|---|---|---|---|---|---|

## Debrief (3 lines)
- What was covered, what was not, what to automate (hand `/cover` the step).
