# /verify Confidence Score — design spec

Status: DRAFT (not yet applied to core/commands/verify.md)
Replaces: low/medium/high self-reported confidence.

## Principle

The score is **computed from countable gates, never self-reported**. A model's
"87% confident" is generated text — false precision. Here, the number falls out
of arithmetic over evidence-backed checks, so 100% means literally "every gate
passed and every claim has a receipt," and a low score names exactly which
gates block.

## Gate states (exactly three)

| State | Meaning | Requirement |
|---|---|---|
| `PASS` | Machine-verified true | Receipt attached |
| `FAIL` | Machine-verified false | Receipt attached (showing the failure) |
| `UNVERIFIED` | No machine evidence possible in this environment | Must name the human step that confirms it |

Rules:
- A machine-verifiable gate **without a receipt counts as FAIL**, not PASS —
  a claim the model didn't (or can't) evidence never scores.
- Human-only gates (visual correctness on a sideload-only surface, behavior on
  a deployed env, anything the harness can't drive) are **born UNVERIFIED** and
  stay so until a human confirmation is recorded in the ticket state file
  (e.g. a `[qa-confirmed]` event). The model may never flip these itself.

## Receipt format

Every PASS/FAIL gate carries:

```yaml
receipt:
  cmd: "<exact command run>"        # e.g. npx jest --testPathPattern=export
  exit: 0                            # actual exit code
  evidence: "<= 3 quoted lines of output, verbatim>"
  ref: "path/to/file.ts:41"          # when the claim is about code
```

Receipts are spot-checkable by a dumb script: `grep -F "<evidence line>"` in the
named file / re-run of `cmd` comparing exit codes. The verifier agent GATHERS
receipts; it does not grade itself.

## Gate list (derived, not invented per run)

1. **Per AC** (from the ticket): three gates each — exists / substantive (not a
   stub) / wired (imported, rendered, reachable). Machine-verifiable.
2. **Standard battery** (from repo profile config: `lint_command`,
   `test_command`, `build_command`, contract check when API types changed).
   Machine-verifiable. Tests/build are BLOCKING.
3. **Surface gates** (from the surface's QA checklist, e.g. ui-fidelity output):
   human-only on surfaces the harness can't drive → born UNVERIFIED.

## Scoring rule (deterministic — computed by script, not by the model)

```
raw   = passed_gates / total_gates
score = raw, then apply caps:
  any BLOCKING gate FAIL   -> cap at 30%   ("this will break")
  any gate UNVERIFIED      -> cap at 70%   ("looks right; human confirmation pending")
  any receipt spot-check mismatch -> cap at 30% and flag the gate (claimed evidence not found)
100% is reachable ONLY when: all machine gates PASS with valid receipts
                             AND all human gates carry a recorded confirmation.
```

## Bands

| Score | Reading |
|---|---|
| 90–100 | Ship. Everything evidenced, humans confirmed. |
| 70–89 | Medium — machine-green, human gates pending. The score CANNOT rise past this band by model output alone. |
| 31–69 | Gaps — failed/unevidenced gates named individually. |
| ≤30 | Will break — a blocking gate failed. |

## Output format (end of /verify report)

```
| Gate                     | State      | Receipt / Owner                      |
|--------------------------|------------|--------------------------------------|
| AC-1 exists              | PASS       | grep -n "onExport" ExportButton.tsx:41 (exit 0) |
| AC-1 wired               | PASS       | rendered via Toolbar.tsx:12 (exit 0) |
| AC-2 empty-state         | FAIL       | grep 0 hits; no test found           |
| Unit tests    [BLOCKING] | PASS       | jest exit 0 — "47 passed, 47 total"  |
| Lint                     | PASS       | eslint exit 0                        |
| Visual: sidebar layout   | UNVERIFIED | human: in-app QA on target surface   |

Score: 62% (5/6 gates) — capped by: AC-2 FAIL. After fix: max 70% until visual QA confirmed.
```

## Implementation notes

- The scoring script (~20 lines of shell/python) lives in core/scripts/; it
  parses the gate table, validates receipt presence, spot-checks `evidence`
  strings with grep -F, re-checks exit codes where cheap, and prints the score.
  This is the rung-3 layer: the number is never model-authored.
- Weak-model property: a weaker model may gather receipts more slowly, but it
  cannot inflate the score — missing/false receipts fail closed.
- Human confirmations append an event to the ticket state file; re-running
  /verify after confirmation lifts the 70% cap without re-running machine gates.
