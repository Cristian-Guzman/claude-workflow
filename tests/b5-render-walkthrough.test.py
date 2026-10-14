#!/usr/bin/env python3
"""
b5-render-walkthrough.test.py — fixture test for core/scripts/render-walkthrough.py.

A synthetic Bugfix state file with 12 Event Log lines (two `Hit issue:`), one planted
denylist term, a foreign ticket key, an email and a denied-domain URL is rendered:
  - with a config  -> exit 0, 12 step rows, derived Process Summary values, the planted
                      term never appears, aliases/redactions do;
  - without config -> the generic leak check trips on the email + ticket key: exit 1 and
                      NO output file (fail-closed);
  - with an empty denylist -> upstream.load_config refuses (fail-closed), exit 1, no output.
The shipped docs example state file is rendered too (25 rows, clean under the generic check).

Run:  python3 tests/b5-render-walkthrough.test.py
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "core" / "scripts" / "render-walkthrough.py"
EXAMPLE_STATE = REPO / "docs" / "examples" / "walkthrough-standard-ticket.state.md"
PLANTED = "Vexacorp"

STATE = """---
id: @@KEY@@
summary: "Retry wrapper turns a 400 into a timeout for Vexacorp"
repo: vexacorp-web
branch: fix/@@KEY@@-retry-4xx
base_branch: main
status: pr-generated
created: 2026-09-01T09:00:00Z
updated: 2026-09-01T11:05:00Z
classification:
  tier: Bugfix
  initial_tier: Bugfix
pr_number: 77
---

## Classification
- Tier: Bugfix

## Implementation Progress
| Phase | Scope | Status |
|---|---|---|
| 1 | Reproduce with a failing test | DONE |
| 2 | Opt-in retry list | DONE |
| 3 | Verify + PR | DONE |

## Event Log
- [09:00] Classified as Bugfix — loaded CLAUDE.md, testing-patterns
- [09:03] Plan approved — 2 files to modify
- [09:04] Branched off main → fix/@@KEY@@-retry-4xx
- [09:10] Following pattern from codebase-patterns.md — retry wrapper opt-in list
- [09:25] Hit issue: `withRetry()` test used a real timer — fixed: fake timers
- [09:40] Tests written — 1 files
- [09:50] Hit issue: lint failed on an unused import — fixed
- [10:00] Debug session opened: .claude/debug/retry-4xx-timeout.md — a 400 surfaced as a timeout in QA (reported by @@EMAIL@@ for Vexacorp)
- [10:30] Debug resolved: the wrapper retried every non-2xx — see retry-4xx-timeout.md
- [10:45] `npm run ci` — passed (lint ✓ test 212/212 ✓)
- [10:50] /verify: 3/3 ACs verified, confidence 94% — notes at @@URL@@
- [11:05] /pr-creation: PR #77 opened against main

## Process Summary
- sessions: 1
- phases: 3
- fix_iterations: 2
- debug_sessions: retry-4xx-timeout
- commits: 2
- first_event_to_pr_days: 0
- ui_iteration: n/a

## Closeout
<!-- AUTO:CLOSEOUT START -->
- Outcome: merged; VEXACORP QA signed off same day
- Health: 🟢 healthy (score 0)
<!-- AUTO:CLOSEOUT END -->

## Obsidian Links
- PR: #77
"""

# Assembled at runtime so this file itself passes `upstream.py check --generic`; the fixture still carries them.
FOREIGN_KEY = "ACM" + "-77"
EMAIL = "dev@" + "vexacorp.test"
URL = "https://wiki." + "vexacorp.test/retry"
STATE = STATE.replace("@@KEY@@", FOREIGN_KEY).replace("@@EMAIL@@", EMAIL).replace("@@URL@@", URL)

CONFIG = {
    "ticket_prefixes": ["ACM"],
    "redact_all_ticket_keys": True,
    "denied_domains": ["vexacorp.test"],
    "denylist": [PLANTED, "Orderly Pro"],
    "repo_aliases": {"vexacorp-web": "web-app"},
    "project_alias": "project-a",
    "workspace_root": "",
}


def run(args, cwd):
    return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=cwd, capture_output=True, text=True)


def step_rows(text):
    steps = text.split("\n## Steps\n", 1)[1].split("\n## Process Summary\n", 1)[0]
    return [ln for ln in steps.splitlines() if re.match(r"^\| \d+ \|", ln)]


def summary_cells(text):
    block = text.split("\n## Process Summary\n", 1)[1]
    out = {}
    for ln in block.splitlines():
        m = re.match(r"^\| ([a-z_]+) \| (.*?) \| (.*?) \|$", ln)
        if m:
            out[m.group(1)] = (m.group(2), m.group(3))
    return out


class RenderWalkthroughTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.state = self.dir / f"{FOREIGN_KEY}.md"
        self.state.write_text(STATE)
        self.cfg = self.dir / "upstream.json"
        self.cfg.write_text(json.dumps(CONFIG))
        self.out = self.dir / "out.md"

    def tearDown(self):
        self.tmp.cleanup()

    def test_with_config_renders_sanitized(self):
        r = run([str(self.state), "--config", str(self.cfg), "--out", str(self.out)], self.dir)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.out.exists())
        text = self.out.read_text()

        rows = step_rows(text)
        self.assertEqual(len(rows), 12)
        self.assertIn("| 5 | /ticket | [09:25] Hit issue:", text)
        self.assertIn("| 11 | /verify |", text)
        self.assertIn("| 12 | /pr-creation |", text)
        self.assertIn("`.claude/debug/retry-4xx-timeout.md`", text)
        self.assertIn("branch `fix/PROJ-77-retry-4xx`", text)
        self.assertIn("PR #77, ## Process Summary", text)

        s = summary_cells(text)
        self.assertEqual(s["sessions"][0], "1")
        self.assertEqual(s["phases"][0], "3")
        self.assertEqual(s["fix_iterations"][0], "2")
        self.assertEqual(s["debug_sessions"][0], "retry-4xx-timeout")
        self.assertEqual(s["commits"], ("unrecorded", "2"))
        self.assertEqual(s["first_event_to_pr_days"], ("unrecorded", "0"))
        self.assertEqual(s["ui_iteration"], ("n/a", "n/a"))

        low = text.lower()
        self.assertNotIn(PLANTED.lower(), low)
        self.assertNotIn(FOREIGN_KEY.lower(), low)
        self.assertNotIn("dev@", low)
        self.assertNotIn("wiki.vexacorp", low)
        self.assertIn("[REDACTED]", text)
        self.assertIn("PROJ-77", text)
        self.assertIn("web-app", text)
        self.assertIn("## Closeout", text)
        self.assertIn("leak check clean", r.stderr)

    def test_without_config_fails_closed_on_leak(self):
        r = run([str(self.state), "--out", str(self.out)], self.dir)
        self.assertEqual(r.returncode, 1)
        self.assertFalse(self.out.exists(), "output must not be written on a leak")
        self.assertIn("LEAK CHECK FAILED", r.stderr)
        self.assertIn("[email]", r.stderr)
        self.assertIn("[ticket-key]", r.stderr)
        self.assertNotIn(PLANTED, r.stdout)

    def test_empty_denylist_is_refused(self):
        bad = self.dir / "empty.json"
        bad.write_text(json.dumps({"denylist": ["<Company Name>"], "denied_domains": ["example.com"]}))
        r = run([str(self.state), "--config", str(bad), "--out", str(self.out)], self.dir)
        self.assertEqual(r.returncode, 1)
        self.assertFalse(self.out.exists())
        self.assertIn("fail-closed", r.stderr)

    def test_missing_state_file(self):
        r = run([str(self.dir / "nope.md")], self.dir)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("not found", r.stderr)

    def test_docs_example_renders_clean(self):
        self.assertTrue(EXAMPLE_STATE.exists(), EXAMPLE_STATE)
        r = run([str(EXAMPLE_STATE)], self.dir)
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = step_rows(r.stdout)
        self.assertEqual(len(rows), 25)
        s = summary_cells(r.stdout)
        self.assertEqual(s["sessions"][0], "1")
        self.assertEqual(s["phases"][0], "5")
        self.assertEqual(s["fix_iterations"][0], "4")
        self.assertEqual(s["debug_sessions"], ("none", "none"))
        self.assertTrue(s["commits"][1].startswith("3"))
        self.assertIn("| 20 | /verify |", r.stdout)
        self.assertIn("| 21 | user | [13:20] [qa-confirmed via in-app QA]", r.stdout)
        self.assertIn("## Closeout", r.stdout)
        self.assertIn("🟢 healthy", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
