#!/usr/bin/env python3
"""
b4-harvest-profile.test.py — fixture test for core/scripts/harvest-profile.py.

Builds a tiny synthetic workspace (two repos, one e2e suite, a state index, proposals,
a CI run export, a fake public core) with a planted denylist term in a section title,
then asserts: the counts are right, the term never reaches the output, and the exit
codes behave (0 clean · 1 config error · 2 leak survives redaction → nothing written).

Usage: python3 tests/b4-harvest-profile.test.py
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
SCRIPT = HERE / "core" / "scripts" / "harvest-profile.py"
PLANTED = "Zorblax"            # denylist term planted into an H2 title and an agent name
PLANTED_DOMAIN = "zorblax-corp.test"
PROJECT_ALIAS = "project-a"   # local provenance: upstream.py check flags it, sanitize leaves it → redaction loop


def load_module():
    spec = importlib.util.spec_from_file_location("harvest_profile", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def write(p, text):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)


def build_workspace(root):
    ws = root / "work" / ".claude"
    repo_a = root / "work" / "shop-frontend"
    repo_b = root / "work" / "orders-service"
    write(ws / "workflow-version.md", "---\nversion: 0.8.0\n---\n# v\n")
    write(ws / "repo-profiles" / "_schema.yaml", "name: example\n")
    write(ws / "repo-profiles" / "shop-frontend.yaml",
          "name: shop-frontend\ntype: frontend-ui\nbase_branch: develop\ntracker_system: jira\n"
          "component_organization: atomic\ne2e:\n  enabled: true\n  framework: playwright\n  spec_dir: \"e2e/\"\n"
          "  sideload_only: false\ndeploy:\n  model: \"\"\n")
    write(ws / "repo-profiles" / "orders-service.yaml",
          "name: orders-service\ntype: backend-service\nbase_branch: release_candidate\ntracker_system: none\n"
          "e2e:\n  enabled: false\ndeploy:\n  model: k8s-argo\n")
    write(ws / "settings.json", json.dumps({
        "env": {"WORKFLOW_LAYOUT": "workspace"},
        "permissions": {"allow": ["Bash(gh pr:*)", "Bash(gh api:*)", "Read(~/secret/**)", "WebFetch(domain:localhost)"]},
        "hooks": {"PreToolUse": [{}, {}], "PostToolUse": [{}]}}))
    write(ws / "state" / "index.json", json.dumps({"version": 2, "generated": "", "entries": [
        {"id": "a:ticket:ZZZ-100", "repo": "shop-frontend", "kind": "ticket", "key": "ZZZ-100", "status": "learned",
         "created": "2026-01-01T00:00:00Z", "updated": "2026-01-05T00:00:00Z", "archived": True, "pr": 12,
         "tags": {"layer": "ui", "kind": "feature"}, "tagged_by": "heuristic", "tag_confidence": "high"},
        {"id": "a:ticket:ZZZ-101-clarify", "repo": "shop-frontend", "kind": "ticket", "key": "ZZZ-101-clarify", "status": "delivered",
         "created": "2026-02-01T00:00:00Z", "updated": "2026-02-03T00:00:00Z", "archived": False, "pr": None,
         "tags": {"layer": "ui", "kind": "bugfix"}, "tagged_by": "heuristic", "tag_confidence": "low"},
        {"id": "b:debug:slow-orders", "repo": "orders-service", "kind": "debug", "key": "slow-orders", "status": "in-progress",
         "created": "2026-03-01T00:00:00Z", "updated": "2026-03-01T01:00:00Z", "archived": False, "pr": None},
    ]}))
    write(ws / "state" / "schema-drift.log",
          "2026-07-14 non-schema status 'implementing' in /x/ZZZ-1.md\n2026-07-15 non-schema status 'implementing' in /x/ZZZ-2.md\n")
    write(ws / "command-proposals.md",
          "# Proposals\n\n### [2026-01-10] /verify — old open thing\n**Target:** verify.md §3\n**Status:** OPEN\n**Occurrences:** 2\n\n"
          "### [2026-09-30] /pr — recent\n**Target:** pr.md §8\n**Status:** ADDRESSED 2026-10-01\n\n"
          "### [2026-05-01] /foo — local-only command\n**Target:** foo.md §1\n**Status:** STALE\n")
    write(ws / "capability-manifest.md", "| Command | Decision | Reason |\n|---|---|---|\n| /do | PRUNE | x |\n| /build | KEEP (watch) | y |\n")
    write(ws / "commands" / "verify.md", "# verify\nline\n")
    write(ws / "commands" / "pr.md", "# pr\n")
    write(ws / "commands" / "foo.md", "# local only\n")
    write(ws / "agents" / "verifier.md", "---\nname: verifier\ntools: Read, Grep\nmodel: opus\n---\nbody\n")
    write(ws / "metrics" / "2026-06-01.json", json.dumps({"schema_version": 3, "metrics": {"learn_churn": {}, "ticket_cycle_time": {}}}))
    write(ws / "metrics" / "2026-07-01.json", json.dumps({"schema_version": 3, "metrics": {"learn_churn": {}}}))

    # repo A — frontend with an e2e suite; the planted term sits in an H2 title and an agent name
    write(repo_a / ".claude" / "codebase-patterns.md", "\n".join([
        "<!-- last-updated: 2026-09-01 -->", "<!-- last-run: 2026-09-01: +1 -0 -->", "<!-- last-run: 2026-08-01: +2 -0 -->",
        "# Codebase Patterns — shop-frontend", "",
        "Full ladder: [[codebase-patterns-shared.md]]", "",
        "## Index", "- [a](#a) — Source: [[ZZZ-100]]", "- [b](#b) — Source: session", "",
        f"## {PLANTED} widget quirks", "",
        "### [Pattern]: a", "- **Rule**: do a", "- **Why**: because", "_Source: [[ZZZ-100]]_", "",
        "### [Gotcha]: b", "text", "_Source: session 2026-08-01_", "",
        f"## Quirks of {PROJECT_ALIAS}", "", "### [Pattern]: c", "l1", "l2", "l3", "l4", "l5", "l6", "l7", "l8", "l9", "_Source: code-observation_", "",
        "## Code comment hygiene", "one line.", "", "## Lessons Learned", ""]))
    write(repo_a / ".claude" / "testing-patterns.md", "\n".join([
        "# Testing Patterns — shop-frontend", "", "## Mock Patterns", "### Mock the module", "rule", "_Source: [[ZZZ-101]]_", "",
        "## E2E drift taxonomy", "<!-- e2e-suite-health: specs=2 -->", "", "## E2E suite health", ""]))
    write(repo_a / ".claude" / "ticket-checklist.md", "# Checklist\n- [ ] one\n- [ ] two\n")
    write(repo_a / ".claude" / "agents" / f"{PLANTED.lower()}-reviewer.md",
          f"---\nname: {PLANTED}-reviewer\ntools: Read, Bash\nmodel: opus\n---\nbody\n")
    write(repo_a / ".claude" / "process-ledger.md", "\n".join([
        "# Process Ledger", "", "## AUTO:PROCESS-LOG",
        "- 2026-07-01 ZZZ-100 class=feature-ui sessions=2 phases=5 fix_iter=3 debug=none days=4",
        "- 2026-07-02 ZZZ-101 class=feature-ui sessions=1 phases=4 fix_iter=1 debug=slow-thing days=0",
        "- 2026-07-03 ZZZ-102 class=dependabot sessions=1 phases=3 fix_iter=0 debug=none days=0", "",
        "## AUTO:PROCESS-LESSONS", "### [class=feature-ui] lesson", "text", "- **bullet** text", ""]))
    write(repo_a / ".claude" / "ui-fidelity-ledger.md",
          "# UI\n## AUTO:META-LESSONS\n<!-- ui-iteration-kpi: seeded -->\n### [surface=web · cluster=per-state-contract] x\nbody\n")
    write(repo_a / "playwright.config.ts", "\n".join([
        "import { defineConfig } from '@playwright/test';", "export default defineConfig({",
        "  testDir: './e2e',", "  fullyParallel: true,", "  forbidOnly: !!process.env.CI,",
        "  retries: process.env.CI ? 2 : 0,", "  workers: process.env.CI ? 2 : undefined,",
        "  reporter: process.env.CI ? [['html'], ['junit', { outputFile: 'r.xml' }]] : 'list',",
        "  timeout: 60_000,", "  use: { baseURL: 'https://shop.zorblax-corp.test', trace: 'on-first-retry', screenshot: 'only-on-failure' },",
        "  projects: [", "    { name: 'setup', testMatch: /.*\\.setup\\.ts/ },", "    { name: 'chromium', use: {} },", "  ],",
        "  webServer: { command: 'yarn dev', url: 'https://localhost:3000' },", "});"]))
    write(repo_a / "e2e" / "items" / "list.spec.ts", "\n".join([
        "import { test, expect } from '@playwright/test';",
        "test.describe('items', () => {",
        "  test('lists', async ({ page }) => { await page.getByRole('button', { name: 'Add' }).click(); await page.getByRole('list'); });",
        "  test('text', async ({ page }) => { await page.getByText('Items'); await page.locator('[class*=row]').first(); });",
        "  test.skip('broken', async ({ page }) => { await page.getByTestId('x'); });",
        "  test.fixme('hang', async () => {});",
        "  test('guarded', async ({ page }) => { const v = await page.getByText('y').isVisible().catch(() => false); });",
        "});"]))
    write(repo_a / "e2e" / "items" / "create.spec.ts", "\n".join([
        "import { test } from '@playwright/test';",
        "test('creates', async ({ page }) => { await page.getByRole('textbox'); await page.getByLabel('Name'); await page.waitForTimeout(500); });",
        "test.skip('later', async () => {}); // BUG ZZZ-9", ""]))
    write(repo_a / "e2e" / "pages" / "items.page.ts", "export class ItemsPage {}\n")
    write(repo_a / "e2e" / "fixtures" / "items.ts", "export const items = [];\n")
    write(repo_a / "e2e" / "auth.setup.ts", "export {};\n")
    write(repo_a / "e2e" / "helpers.ts", "export const h = 1;\n")

    # repo B — backend, no e2e, no patterns file yet
    write(repo_b / ".claude" / "testing-patterns.md", "# Testing\n## Table-driven\n### t\nx\n")
    (repo_b / ".claude" / "tickets").mkdir(parents=True)
    write(repo_b / ".claude" / "tickets" / "ZZZ-200.md", "---\nstatus: planning\n---\n")

    # public core snapshot for drift
    core = root / "public" / "core"
    write(core / "commands" / "verify.md", "# verify\n")
    write(core / "commands" / "pr.md", "# pr\n")
    write(core / "commands" / "ticket.md", "# ticket\n")
    write(core / "agents" / "verifier.md", "---\nname: verifier\n---\n")
    write(core / "docs" / "routing.md", "# routing\n")

    # CI export
    write(root / "runs.json", json.dumps([
        {"conclusion": "success", "name": "ci: ZZZ-100 add thing", "workflowName": "CI", "headBranch": "feature/ZZZ-100", "headSha": "aaa", "attempt": 1, "createdAt": "2026-09-01T00:00:00Z", "event": "pull_request"},
        {"conclusion": "failure", "name": "ci", "workflowName": "CI", "headBranch": "feature/ZZZ-101", "headSha": "bbb", "attempt": 1, "createdAt": "2026-09-02T00:00:00Z", "event": "pull_request"},
        {"conclusion": "success", "name": "ci", "workflowName": "CI", "headBranch": "feature/ZZZ-101", "headSha": "bbb", "attempt": 2, "createdAt": "2026-09-02T01:00:00Z", "event": "pull_request"},
        {"conclusion": "success", "name": "nightly", "workflowName": "Nightly E2E", "headBranch": "develop", "headSha": "ccc", "attempt": 1, "createdAt": "2026-09-11T00:00:00Z", "event": "schedule"},
    ]))

    write(root / "upstream.json", json.dumps({
        "public_repo": "x/claude-workflow", "project_alias": PROJECT_ALIAS, "workspace_root": str(root / "work"),
        "ticket_prefixes": ["ZZZ"], "redact_all_ticket_keys": True,
        "denied_domains": [PLANTED_DOMAIN],
        "denylist": [PLANTED, "Internal Codename"],
        "repo_aliases": {"shop-frontend": "web-app"},
    }))
    write(root / "upstream-empty.json", json.dumps({"denylist": ["<Company Name>"], "denied_domains": ["example.com"], "repo_aliases": {}}))
    return ws


class HarvestProfileTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix="b4-harvest."))
        cls.ws = build_workspace(cls.tmp)
        cls.out = cls.tmp / "out"
        cls.mod = load_module()
        cls.proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--workspace", str(cls.ws), "--config", str(cls.tmp / "upstream.json"),
             "--out", str(cls.out), "--ci-runs", str(cls.tmp / "runs.json"), "--public-core", str(cls.tmp / "public" / "core")],
            capture_output=True, text=True)
        cls.profile = json.loads((cls.out / "profile.json").read_text()) if (cls.out / "profile.json").exists() else None

    def test_cli_exit_0_and_outputs(self):
        self.assertEqual(self.proc.returncode, 0, self.proc.stdout + self.proc.stderr)
        self.assertTrue((self.out / "profile.json").exists())
        self.assertTrue((self.out / "profile.md").exists())
        self.assertIn("check pass", self.proc.stdout)

    def test_planted_term_never_appears(self):
        blob = (self.out / "profile.json").read_text() + (self.out / "profile.md").read_text()
        self.assertNotIn(PLANTED.lower(), blob.lower())
        self.assertNotIn(PLANTED_DOMAIN, blob)
        self.assertNotIn(PROJECT_ALIAS, blob)
        self.assertNotIn("shop-frontend", blob)          # real repo name → alias
        self.assertNotIn("ZZZ-", blob)                   # ticket keys never leave
        self.assertNotIn(str(self.tmp), blob)            # no paths
        self.assertNotIn("shop.", blob)                  # baseURL never leaves
        self.assertNotIn("feature/", blob)               # branch names never leave

    def test_redaction_placeholders_present(self):
        titles = self.profile["repos"]["web-app"]["codebase_patterns"]["h2_titles"]
        # denylist term: caught by the sanitizer rules (upstream.py build_rules) before check runs
        self.assertIn("[REDACTED] widget quirks", titles)
        # project alias: sanitize leaves it, check flags it → the redaction loop renames the title
        self.assertTrue(any(t.startswith("<redacted-title-") for t in titles), titles)
        self.assertFalse(any(PROJECT_ALIAS in t for t in titles), titles)
        names = [a["name"] for a in self.profile["repos"]["web-app"]["agents"]]
        self.assertEqual(names, ["[REDACTED]-reviewer"])
        self.assertEqual(self.profile["sanitization"]["redacted_strings"], 1)
        self.assertGreaterEqual(self.profile["sanitization"]["redactions"].get("denylist", 0), 2)
        self.assertEqual(self.profile["sanitization"]["check"], "pass")

    def test_pattern_file_structure_counts(self):
        cp = self.profile["repos"]["web-app"]["codebase_patterns"]
        self.assertEqual(cp["h2"], 5)
        self.assertEqual(cp["h3"], 3)
        self.assertEqual(cp["index_lines"], 2)
        self.assertEqual(cp["last_run_lines"], 2)
        self.assertEqual(cp["tags"], {"Pattern": 2, "Gotcha": 1})
        self.assertEqual(cp["source_mix"]["ticket"], 1)
        self.assertEqual(cp["source_mix"]["session"], 1)
        self.assertEqual(cp["source_mix"]["code_observation"], 1)
        self.assertEqual(cp["entries_le_8_lines"], 2)
        self.assertEqual(cp["entry_lines"]["max"], 11)
        self.assertTrue(cp["has_shared_pointer"])
        self.assertTrue(cp["has_comment_hygiene_h2"])
        self.assertEqual(cp["index_coverage"], 0.67)
        tp = self.profile["repos"]["web-app"]["testing_patterns"]
        self.assertTrue(tp["has_e2e_drift_taxonomy_h2"] and tp["has_e2e_suite_health_h2"])
        self.assertEqual(tp["suite_health_stamps"], 1)
        self.assertEqual(self.profile["repos"]["web-app"]["ticket_checklist"]["checkboxes"], 2)

    def test_e2e_counts(self):
        e2 = self.profile["repos"]["web-app"]["e2e"]
        self.assertEqual(e2["spec_files"], 2)
        self.assertEqual(e2["page_object_files"], 1)
        self.assertEqual(e2["fixture_files"], 1)
        self.assertEqual(e2["setup_files"], 1)
        self.assertEqual(e2["helper_files"], 3)          # pages/items.page.ts, fixtures/items.ts, helpers.ts
        self.assertEqual(e2["tests_total"], 7)           # 5 in list (incl. skip/fixme) + 2 in create
        self.assertEqual(e2["selectors"]["getByRole"], 3)
        self.assertEqual(e2["selectors"]["getByText"], 2)
        self.assertEqual(e2["selectors"]["getByTestId"], 1)
        self.assertEqual(e2["selectors"]["getByLabel"], 1)
        self.assertEqual(e2["selectors"]["locator_class_contains"], 1)
        self.assertEqual(e2["selectors"]["waitForTimeout"], 1)
        self.assertEqual(e2["guards"]["test_skip"], 2)
        self.assertEqual(e2["guards"]["test_fixme"], 1)
        self.assertEqual(e2["guards"]["test_only"], 0)
        self.assertEqual(e2["guards"]["soft_guard"], 1)
        self.assertEqual(e2["guards"]["skip_with_key"], 0)  # the BUG key sits in a trailing comment, not the call
        self.assertAlmostEqual(e2["guard_density_per_100_tests"]["test_skip"], 28.57, places=2)
        pw = self.profile["repos"]["web-app"]["playwright_config"]
        self.assertEqual(pw["retries"], {"ci": 2, "local": 0})
        self.assertEqual(pw["workers"], {"ci": 2, "local": None})
        self.assertEqual(pw["reporters"], ["html", "junit", "list"])
        self.assertEqual(pw["projects"], 2)
        self.assertEqual(pw["trace"], "on-first-retry")
        self.assertEqual(pw["timeout_ms"], 60000)
        self.assertTrue(pw["has_base_url"] and pw["has_web_server"] and pw["fully_parallel"])
        self.assertFalse(self.profile["repos"]["repo-" + self.mod.sha12("orders-service")[:8]]["e2e"]["present"])

    def test_workspace_aggregates(self):
        ws = self.profile["workspace"]
        self.assertEqual(ws["repos"], 2)
        self.assertEqual(ws["layout"], "workspace")
        self.assertEqual(ws["workflow_version"], "0.8.0")
        si = ws["state_index"]
        self.assertEqual(si["entries"], 3)
        self.assertEqual(si["by_kind"], {"ticket": 2, "debug": 1})
        self.assertEqual(si["by_status"], {"delivered": 1, "in-progress": 1, "learned": 1})
        self.assertEqual(si["key_suffixes"], {"(none)": 1, "-clarify": 1, "slug": 1})
        self.assertEqual(si["cycle_time_days_created_to_last_update"]["n"], 2)
        self.assertEqual(si["cycle_time_days_created_to_last_update"]["mean"], 3.0)
        self.assertEqual(si["by_repo_alias"]["web-app"], 2)
        pr = ws["proposals"]
        self.assertEqual(pr["blocks"], 3)
        self.assertEqual(pr["by_status"], {"ADDRESSED": 1, "OPEN": 1, "STALE": 1})
        self.assertEqual({t["label"]: t["n"] for t in pr["targets"]}, {"verify": 1, "pr": 1, "other": 1})
        self.assertEqual(pr["occurrences"], {"1": 2, "2": 1})
        self.assertEqual(ws["capability_enums"]["type"], {"backend-service": 1, "frontend-ui": 1})
        self.assertEqual(ws["capability_enums"]["base_branch_is_default"], {"False": 1, "True": 1})
        self.assertEqual(ws["capability_manifest"]["decisions"], {"KEEP": 1, "PRUNE": 1})
        self.assertEqual(ws["settings"]["permissions_allow"], 4)
        self.assertEqual(ws["settings"]["permissions_by_tool"], {"Bash": 2, "Read": 1, "WebFetch": 1})
        self.assertEqual(ws["settings"]["hooks"], {"PreToolUse": 2, "PostToolUse": 1})
        self.assertEqual(ws["metrics"]["snapshots"], 2)
        self.assertEqual(ws["metrics"]["span_days"], 30)
        self.assertEqual(ws["schema_drift"]["distinct_statuses"], [{"label": "implementing", "n": 2}])
        self.assertEqual(ws["commands"]["local_only"], ["foo"])
        self.assertEqual(ws["commands"]["in_public_core"], ["pr", "verify"])

    def test_process_and_ui_ledgers(self):
        pl = self.profile["repos"]["web-app"]["process_ledger"]
        self.assertEqual(pl["log_rows"], 3)
        fe = [c for c in pl["classes"] if c["label"] == "feature-ui"][0]
        self.assertEqual(fe["n"], 2)
        self.assertEqual(fe["mean_fix_iter"], 2.0)
        self.assertEqual(fe["with_debug"], 1)
        self.assertEqual(pl["lessons_h3"], 1)
        self.assertEqual(pl["lessons_bullets"], 1)
        ul = self.profile["repos"]["web-app"]["ui_fidelity_ledger"]
        self.assertEqual(ul["meta_lessons"], 1)
        self.assertEqual(ul["clusters"], {"per-state-contract": 1})

    def test_ci_aggregates_hashed(self):
        ci = self.profile["ci"]
        self.assertEqual(ci["runs"], 4)
        self.assertEqual(ci["workflows"], 2)
        for h in ci["by_workflow_hash"]:
            self.assertRegex(h, r"^[0-9a-f]{12}$")
        main = ci["by_workflow_hash"][self.mod.sha12("CI")]
        self.assertEqual(main["runs"], 3)
        self.assertEqual(main["by_conclusion"], {"success": 2, "failure": 1})
        self.assertEqual(main["failure_rate"], 0.333)
        self.assertEqual(main["reruns"], 1)
        self.assertEqual(main["same_sha_flips"], 1)
        self.assertEqual(main["distinct_branches"], 2)
        self.assertNotIn("Nightly", json.dumps(ci))

    def test_drift_counts(self):
        d = self.profile["drift"]
        self.assertTrue(d["compared"])
        by_file = {f["file"]: f for f in d["files"]}
        self.assertEqual(by_file["commands/verify.md"]["status"], "modified")
        self.assertEqual(by_file["commands/verify.md"]["changed_lines"], 1)
        self.assertEqual(by_file["commands/ticket.md"]["status"], "missing")
        self.assertEqual(by_file["docs/routing.md"]["status"], "missing")
        self.assertNotIn("commands/pr.md", by_file)       # identical → not listed
        self.assertEqual(by_file["agents/verifier.md"]["changed_lines"], 3)
        self.assertEqual(d["modified"], 2)
        self.assertEqual(d["missing"], 2)
        self.assertIn("commands/foo.md", d["local_only"])
        self.assertNotIn("docs/command-proposals.md", d["local_only"])   # project-owned root files are not drift
        self.assertEqual(d["local_only_count"], len(d["local_only"]))

    def test_dry_run_writes_nothing(self):
        out = self.tmp / "dry-out"
        p = subprocess.run([sys.executable, str(SCRIPT), "--workspace", str(self.ws), "--config", str(self.tmp / "upstream.json"),
                            "--out", str(out), "--dry-run"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("dry-run, nothing written", p.stdout)
        self.assertFalse(out.exists())

    def test_empty_denylist_is_a_config_error(self):
        out = self.tmp / "cfg-out"
        p = subprocess.run([sys.executable, str(SCRIPT), "--workspace", str(self.ws), "--config", str(self.tmp / "upstream-empty.json"),
                            "--out", str(out)], capture_output=True, text=True)
        self.assertEqual(p.returncode, 1)
        self.assertIn("fail-closed", p.stderr)
        self.assertFalse(out.exists())

    def test_leak_surviving_redaction_writes_nothing_exit_2(self):
        out = self.tmp / "leak-out"
        args = argparse.Namespace(workspace=str(self.ws), repos=None, config=str(self.tmp / "upstream.json"), out=str(out),
                                  ci_runs=None, public_core=None, dry_run=False, max_redaction_rounds=0)
        import io, contextlib
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = self.mod.harvest(args, today=date(2026, 10, 12))
        self.assertEqual(rc, 2)
        self.assertFalse(out.exists())
        self.assertIn("nothing written", err.getvalue())
        self.assertIn("h2_titles", err.getvalue())        # the offending key is named
        self.assertNotIn(PLANTED, err.getvalue())        # and the term itself is not echoed

    def test_md_render_has_tables(self):
        md = (self.out / "profile.md").read_text()
        self.assertIn("| web-app | frontend-ui |", md)
        self.assertIn("selector strategy", md)
        self.assertIn("## Drift vs public core", md)
        self.assertIn("<redacted-title-", md)

    @classmethod
    def tearDownClass(cls):
        import shutil
        shutil.rmtree(cls.tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
