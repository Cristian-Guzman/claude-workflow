<!-- docs/examples — what /learn §2.7b writes into {repo}/.claude/process-ledger.md after a dozen delivered
     tickets. Neutral content; the shape is the point. One AUTO:PROCESS-LOG row per ticket, copied from the
     `## Process Summary` block /pr-creation §8 wrote at PR time (`unrecorded` is kept as-is and excluded from means);
     an AUTO:PROCESS-LESSONS entry only where ≥2 tickets in one class say the same thing. -->

# Process Ledger — web-app

## AUTO:PROCESS-LOG
- 2026-06-19 PROJ-1066 class=standard-ui sessions=1 phases=4 fix_iter=3 debug=none days=1
- 2026-06-27 PROJ-1072 class=standard-api sessions=2 phases=5 fix_iter=2 debug=none days=3
- 2026-07-03 PROJ-1077 class=standard-e2e sessions=1 phases=3 fix_iter=4 debug=e2e-orders-shared-seed days=2
- 2026-07-11 PROJ-1083 class=bugfix sessions=1 phases=2 fix_iter=1 debug=none days=0
- 2026-07-18 PROJ-1088 class=standard-ui sessions=1 phases=4 fix_iter=3 debug=none days=1
- 2026-07-25 PROJ-1095 class=standard-ui sessions=2 phases=5 fix_iter=4 debug=none days=4
- 2026-08-01 PROJ-1099 class=bugfix sessions=1 phases=2 fix_iter=unrecorded debug=flag-key-missing days=1
- 2026-08-08 PROJ-1103 class=standard-ui sessions=1 phases=4 fix_iter=2 debug=none days=1
- 2026-08-22 PROJ-1109 class=standard-e2e sessions=1 phases=3 fix_iter=2 debug=none days=1
- 2026-08-29 PROJ-1116 class=standard-ui sessions=1 phases=4 fix_iter=2 debug=none days=2
- 2026-09-05 PROJ-1117 class=standard-ui sessions=1 phases=3 fix_iter=1 debug=none days=0
- 2026-09-12 PROJ-1120 class=bugfix sessions=1 phases=2 fix_iter=1 debug=none days=0
- 2026-09-18 PROJ-1131 class=standard-ui sessions=1 phases=5 fix_iter=4 debug=none days=0

## AUTO:PROCESS-LESSONS
<!-- kpi 2026-09-26 (mean, trailing 3 vs prior 3 per class; unrecorded excluded): standard-ui fix_iter 3.0→2.3 sessions 1.3→1.0 · standard-e2e fix_iter 4.0→2.0 (n=1 vs 1) · bugfix fix_iter 1.0→1.0 (n=1 vs 1; PROJ-1099 excluded) -->

### [class=standard-ui] Tickets that skip /clarify spend their fix iterations on the ticket's own file map
Run `/clarify` before `/ticket` on every Standard UI ticket and treat the blueprint's file-map corrections as the plan. The three tickets that went straight to `/ticket` averaged 3.3 `Hit issue:` lines; the four that started from a blueprint averaged 2.3 — and every extra issue in the first group was a file or prop the ticket text got wrong, which the blueprint catches before a line of code exists.
Provenance: [[PROJ-1066]], [[PROJ-1088]], [[PROJ-1095]] (no blueprint) vs [[PROJ-1103]], [[PROJ-1116]], [[PROJ-1117]], [[PROJ-1131]] (blueprint) — 7 tickets
Confidence: HIGH · first_synth=2026-09-12 · last_reinforced=2026-09-26

### [class=standard-e2e] Own the spec's data before writing its first assertion
Write the API fixture that creates and deletes the spec's own order first; only then write the spec. Both e2e tickets spent their fix iterations on state leaking between specs, and the one that opened a debug session was the one that assumed a seeded order would stay stable across the run.
Provenance: [[PROJ-1077]], [[PROJ-1109]] — 2 tickets, 6 fix iterations
Confidence: MED · first_synth=2026-08-22 · last_reinforced=2026-08-22
