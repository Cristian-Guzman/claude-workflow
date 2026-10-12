#!/usr/bin/env python3
"""
Fixture test for roles/sdet/scripts/triage-cluster.py.

Builds a synthetic Playwright JSON report (the shape `--reporter=json` emits:
suites -> specs -> tests -> results) and asserts:
  - 3 specs that die inside one shared helper frame collapse into ONE K1 cluster
  - a test.fail with 'BUG PROJ-123' lands in known_failures, never in a cluster
  - a test.fail WITHOUT a key is a violation, counted as known_failures_unkeyed and
    never as known_failures_with_bug
  - a pass-after-fail test carries flaky_hint and is not counted as passed
  - the four-number summary adds up and never folds known failures into passes;
    passed + failed + known-with-bug + unkeyed + skipped equals the test count
  - the markdown has the two mandatory sections
  - the newman adapter produces endpoint-keyed rows

Usage: python3 tests/b3-triage-cluster.test.py
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "roles" / "sdet" / "scripts" / "triage-cluster.py"

HELPER_STACK = (
    "Error: locator.click: Timeout 30000ms exceeded.\n"
    "Call log:\n  - waiting for getByRole('button', { name: 'Add item' })\n"
    "    at createItem (/repo/e2e/utils/item-helpers.ts:42:19)\n"
    "    at /repo/e2e/items/{spec}:18:5\n"
)


def result(status, retry=0, message=None, stack=None, attachments=None):
    r = {"status": status, "retry": retry, "duration": 1200, "errors": [], "attachments": attachments or []}
    if message:
        r["error"] = {"message": message, "stack": stack or message}
        r["errors"] = [r["error"]]
    return r


def test(title, file, results, expected="passed", annotations=None, line=10):
    return {
        "title": title, "file": file, "line": line, "column": 5, "ok": False, "tags": [],
        "tests": [{
            "timeout": 30000, "annotations": annotations or [], "expectedStatus": expected,
            "projectName": "chromium", "results": results,
            "status": "unexpected",
        }],
    }


def file_suite(file, specs):
    return {"title": file, "file": file, "specs": specs}


def build_report():
    helper_specs = []
    for n, fname in enumerate(["create.spec.ts", "edit.spec.ts", "archive.spec.ts"]):
        f = "e2e/items/" + fname
        msg = HELPER_STACK.replace("{spec}", fname)
        helper_specs.append(file_suite(f, [test(
            "item flow %d works" % n, f,
            [result("failed", 0, msg, msg, [{"name": "trace", "path": "test-results/%s/trace.zip" % fname}])],
        )]))
    known_specs = file_suite("e2e/orders/known.spec.ts", [
        test("totals include tax", "e2e/orders/known.spec.ts",
             [result("failed", 0, "expect(received).toBe(expected)\nExpected: 12\nReceived: 10")],
             expected="failed",
             annotations=[{"type": "fail", "description": "BUG PROJ-123: tax missing from totals"}]),
        test("discount applies", "e2e/orders/known.spec.ts",
             [result("failed", 0, "expect(received).toBe(expected)\nExpected: 9\nReceived: 10")],
             expected="failed",
             annotations=[{"type": "fail", "description": "broken since last week"}]),
    ])
    flaky_spec = file_suite("e2e/search/search.spec.ts", [
        test("search returns results", "e2e/search/search.spec.ts", [
            result("failed", 0, "Error: expect(locator).toBeVisible()\nTimed out 5000ms waiting for getByTestId('results-list')"),
            result("passed", 1),
        ]),
    ])
    green_spec = file_suite("e2e/home/home.spec.ts", [
        test("home renders", "e2e/home/home.spec.ts", [result("passed")]),
        test("footer links", "e2e/home/home.spec.ts", [result("skipped")], expected="skipped"),
    ])
    return {"config": {}, "suites": [
        {"title": "", "specs": [], "suites": helper_specs + [known_specs, flaky_spec, green_spec]},
    ], "errors": []}


def count_tests(node):
    """Total tests in a report (suites -> specs -> tests): the denominator the summary buckets must add up to."""
    direct = sum(len(spec.get("tests") or []) for suite in node.get("suites") or [] for spec in suite.get("specs") or [])
    return direct + sum(count_tests(suite) for suite in node.get("suites") or [])


def build_newman():
    return {
        "collection": {"info": {"name": "orders-api"}},
        "run": {
            "stats": {"assertions": {"total": 4, "failed": 2}},
            "executions": [
                {"item": {"name": "List items"}, "request": {"method": "GET", "url": {"path": ["items"]}},
                 "response": {"code": 500},
                 "assertions": [{"assertion": "status is 200", "error": {"message": "expected 500 to equal 200"}},
                                {"assertion": "has body", "error": {"message": "expected body"}}]},
                {"item": {"name": "Get item"}, "request": {"method": "GET", "url": {"path": ["items", "1"]}},
                 "response": {"code": 200}, "assertions": [{"assertion": "status is 200"}]},
            ],
        },
    }


def run(args):
    p = subprocess.run([sys.executable, str(SCRIPT)] + args, capture_output=True, text=True)
    return p


def main():
    failures, passed = [], []

    def check(cond, label):
        print(("ok   " if cond else "FAIL ") + label)
        (passed if cond else failures).append(label)

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        report = td / "report.json"
        report.write_text(json.dumps(build_report()))
        p = run([str(report), "--key-pattern", "PROJ"])
        check(p.returncode == 0, "exit 0 on a valid report (stderr: %s)" % p.stderr.strip())
        out = json.loads((td / "clusters.json").read_text())
        md = (td / "clusters.md").read_text()

        helper_clusters = [c for c in out["clusters"] if c["key_level"] == "K1"]
        check(len(helper_clusters) == 1, "three specs sharing one helper frame -> exactly one K1 cluster")
        check(helper_clusters and helper_clusters[0]["size"] == 3, "the helper cluster has size 3")
        check(helper_clusters and "e2e/utils/item-helpers.ts:42" in helper_clusters[0]["key"],
              "cluster key is the helper frame (file:line)")
        check(helper_clusters and helper_clusters[0]["class_hint"] == "broken-test",
              "locator-timeout in a helper hints broken-test")
        check(helper_clusters and len(helper_clusters[0]["attachments"]) == 3, "attachments listed per cluster")
        check(out["clusters"][0]["id"] == "C1" and out["clusters"][0]["size"] == 3, "clusters sorted by size desc")

        known = out["known_failures"]
        check(len(known) == 2, "both test.fail tests are known failures (got %d)" % len(known))
        keyed = [k for k in known if k["bug_key"] == "PROJ-123"]
        check(len(keyed) == 1, "BUG PROJ-123 parsed as bug_key")
        check(all("known.spec.ts" not in t for c in out["clusters"] for t in c["tests"]),
              "known failures are never clustered")
        check(len(out["violations"]) == 1 and "discount applies" in out["violations"][0]["id"],
              "test.fail without a key is exactly one violation")

        flaky = [m for c in out["clusters"] for m in c["members"] if "search.spec.ts" in m["file"]]
        check(len(flaky) == 1 and flaky[0]["flaky_hint"] is True, "pass-after-fail carries flaky_hint")
        check(any(c["class_hint"] == "flaky" for c in out["clusters"] if "search.spec.ts" in "".join(c["files"])),
              "flaky-only cluster hints flaky")

        s = out["summary"]
        check(s == {"passed": 1, "failed": 4, "known_failures_with_bug": 1, "known_failures_unkeyed": 1,
                    "skipped": 1, "flaky": 1, "violations": 1},
              "four numbers: passed=1 failed=4 known-with-bug=1 skipped=1, unkeyed=1 (got %s)" % s)
        check(s["known_failures_with_bug"] == len([k for k in known if k["bug_key"]]),
              "known_failures_with_bug counts only entries with a bug_key")
        check(s["known_failures_unkeyed"] == s["violations"] == len(out["violations"]),
              "known_failures_unkeyed equals the violations count")
        total = count_tests(build_report())
        buckets = s["passed"] + s["failed"] + s["known_failures_with_bug"] + s["known_failures_unkeyed"] + s["skipped"]
        check(total == 8 and buckets == total,
              "passed+failed+known-with-bug+unkeyed+skipped == total tests (%d, got %d)" % (total, buckets))
        check("passed=1 failed=4 known-failures-with-bug=1 skipped=1" in p.stdout, "stdout prints the four numbers")
        check("known-failures-unkeyed=1" in p.stdout, "stdout prints the unkeyed count next to the four numbers")
        check("## Known failures with bug (expected-fail, not passes)" in md, "md has the known-failures section")
        check("## Violations" in md and "discount applies" in md, "md lists the violation")
        check("**none**" in md, "md marks the missing bug key")
        check("Known failures with bug: 1 · unkeyed (violations): 1" in md, "md prints keyed and unkeyed counts")

        newman = td / "newman.json"
        newman.write_text(json.dumps(build_newman()))
        p2 = run([str(newman), "--newman", "--out", str(td / "n.json"), "--md", str(td / "n.md")])
        n = json.loads((td / "n.json").read_text())
        check(p2.returncode == 0 and len(n["clusters"]) == 1, "newman: two failed assertions on one endpoint -> one cluster")
        check(n["clusters"][0]["key_level"] == "K3" and "GET /items" in n["clusters"][0]["key"],
              "newman cluster keyed by (class, endpoint, status)")
        check(n["summary"]["passed"] == 2 and n["summary"]["failed"] == 2, "newman summary from run.stats")
        check(n["summary"]["known_failures_with_bug"] == 0 and n["summary"]["known_failures_unkeyed"] == 0,
              "newman summary carries zero known failures, keyed and unkeyed")

        p3 = run([str(td / "missing.json")])
        check(p3.returncode == 1, "unreadable input exits 1")

    print("\n%d checks, %d passed, %d failed" % (len(passed) + len(failures), len(passed), len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
