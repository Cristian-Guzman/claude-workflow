# Batch 5 → Wave 2 handoff

Batch 5 created only `core/scripts/render-walkthrough.py`, `docs/examples/*` and `tests/b5-render-walkthrough.test.py`. Nothing it owns is a hub file; the edits below are requested, not made.

## README.md (Wave 2)
- In the new `## Start here` block, after the Dev trio, add one line:
  `See one ticket go through the whole pipeline: [docs/examples/walkthrough-standard-ticket.md](docs/examples/walkthrough-standard-ticket.md) — and what the pattern file looks like after 20 tickets: [docs/examples/codebase-patterns.after-20-tickets.md](docs/examples/codebase-patterns.after-20-tickets.md).`
- The over-claim fix for the "self-improving" thesis (README.md:3-6, 17-18 per report D §1) can point at the same two files instead of asserting the outcome.

## docs/specialization.md (Wave 2)
- Line ~90 ("noticeably tuned by ticket 5"): append `— see docs/examples/codebase-patterns.after-20-tickets.md for the shape after 20, and its closing sidebar for how real files drift from it.`

## core/docs/workflow-version.md (Wave 2 — 0.8.0 entry)
- Add under scripts: `render-walkthrough.py — state file → sanitized step table + Process Summary (derived vs recorded) + Closeout; imports the upstream.py rule builder and runs its check fail-closed; exit 1 and no output on a hit.`
- Add under docs: `docs/examples/{codebase-patterns.after-20-tickets, process-ledger.example, walkthrough-standard-ticket(.state)}.md`.
- Roadmap pointer: the eval harness was deferred (plan decision S); `docs/examples/walkthrough-standard-ticket.state.md` is the sanitized ticket fixture report D §8 says the first `evals/**/case.yaml` should reuse (report D cross-link 1 ↔ 8).

## docs/roadmap.md (Wave 2 creates it)
- Eval harness entry: "seed case = `docs/examples/walkthrough-standard-ticket.state.md` rendered through `render-walkthrough.py`; grader asserts the step count, the derived Process Summary and a clean `upstream.py check`" — so the fixture is not built twice.

## core/commands/README.md (Wave 2)
- If the file carries a scripts inventory, add `render-walkthrough.py` next to `verify-score.py` with the one-liner above. No new command: the script is invoked by hand (or by `/learn` if Batch 2 wants to offer it — see below).

## Optional — Batch 2 / `learn.md` §5(b) (NOT required for 0.8.0)
- After the Closeout is written, one optional line: `To share this ticket outside the repo: python3 .claude/scripts/render-walkthrough.py .claude/tickets/PROJ-XXXX.md --config .claude/upstream.json --out <file>`. Fold-in, not a new command; skip if §5 is already long.

## install.sh (Batch 1 — informational, no change needed)
- `install.sh:135` copies `core/scripts/*` wholesale, so the new script ships with every install; `install.sh:136` chmods only `*.sh`, which is the existing behaviour for `verify-score.py`/`audit_metrics.py` too (mode bits survive `cp`). Nothing requested.

## Noun sweep (Wave 2) — nothing to add from Batch 5
- All of `docs/examples/*`, the script and the test pass `upstream.py check --generic` and a scratch denylist of the owner's real company/product/people/repo nouns (config kept outside the repo). Three tokens copied too literally from the owner's real files were neutralized before commit (a helper path, a component name, a feature noun).
