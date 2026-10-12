#!/usr/bin/env python3
"""
triage-cluster.py — the deterministic half of /triage.

Turns one test-run report into failure CLUSTERS so the model fixes causes, not
symptoms: three specs that die in the same shared helper are one cluster with one
fix, not three tickets. Stdlib only (macOS system python3 is enough).

Input
  Playwright JSON report (`--reporter=json`, or `npx playwright merge-reports
  --reporter json` over CI blob reports), or a newman JSON export with --newman.

What it does
  1. Walks `suites[]` recursively and keeps every test whose results contain a
     non-passed, non-skipped status. `flaky_hint` marks a test that passed on a
     retry after failing.
  2. KNOWN FAILURES — tests declared `test.fail(...)` (expectedStatus == "failed")
     are listed SEPARATELY, never clustered and never counted as passes. Each must
     carry a bug key in its annotation (`BUG <KEY>-<n>`); one without a key is a
     VIOLATION, counted as `known_failures_unkeyed` and never under
     `known_failures_with_bug`. A known failure whose body now passes is reported
     too: the bug is fixed and the `test.fail` must be removed.
  3. Normalizes error messages (ANSI, durations, hashes, timestamps, unique
     suffixes, element counts, long quoted strings) and extracts: selector, step
     frame (helper frame preferred), endpoint + HTTP status, network error and an
     error_class ∈ {hook-failure, strict-mode, auth-redirect, navigation-timeout,
     network, locator-timeout, assertion-mismatch, unknown}.
  4. Union-find over four keys, most specific first:
       K1 helper frame (file:line under the spec dir's utils/helpers)
       K2 selector
       K3 (error_class, endpoint, status) — only when an endpoint was seen
       K4 (error_class, file) — fallback for tests that carry none of K1–K3
  5. Emits clusters.json + clusters.md sorted by size desc (representative = the
     shortest title), a "Known failures with bug (expected-fail, not passes)"
     section, a "Violations" section, and prints the four-number summary:
     passed / failed / known-failures-with-bug / skipped, followed by
     known-failures-unkeyed (= violations), which is folded into neither passes
     nor known-failures-with-bug.

Usage
  triage-cluster.py REPORT.json [--out clusters.json] [--md clusters.md]
                                [--spec-dir e2e] [--key-pattern 'PROJ'] [--newman]
  Defaults: outputs are written next to REPORT.json. --spec-dir is inferred from
  the first path segment of the failing tests' files when omitted. --key-pattern
  narrows the accepted bug key prefix (default: any [A-Z][A-Z0-9]+).

Exit codes: 0 = report parsed (even with failures); 1 = unreadable input.
"""
import argparse
import json
import re
import sys
from collections import OrderedDict
from pathlib import Path

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
NORMALIZERS = [
    (re.compile(r"\b\d+(\.\d+)?\s?ms\b"), "<ms>"),
    (re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z?"), "<ts>"),
    (re.compile(r"\b[0-9a-f]{8,}\b"), "<hex>"),
    (re.compile(r"\b[a-z0-9]+-\d{6,}\b"), "<unique>"),
    (re.compile(r"\be2e-\d+\b"), "<unique>"),
    (re.compile(r"resolved to \d+ elements?"), "resolved to <n> elements"),
    (re.compile(r"(['\"])[^'\"]{41,}\1"), "<str>"),
]
SELECTOR = re.compile(
    r"(getBy(?:Role|TestId|Text|Label|Placeholder|AltText|Title)\([^)]*\)"
    r"|locator\(['\"][^'\"]+['\"]\))"
)
FRAME = re.compile(r"\(?((?:[A-Za-z]:)?[^\s():]+\.(?:[cm]?[jt]sx?))(?::(\d+))(?::\d+)?\)?")
ENDPOINT = re.compile(r"\b(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+((?:https?://[^\s/]+)?/\S*)")
HTTP_STATUS = re.compile(r"\b([45]\d\d)\b")
NET_ERR = re.compile(r"net::ERR_[A-Z_]+|ECONNREFUSED|ECONNRESET|ENOTFOUND|ETIMEDOUT")
AUTH_URL = re.compile(r"https?://[^\s\"']*/(login|signin|sign-in|auth)\b", re.I)
BUG_KEY = re.compile(r"BUG\s+([A-Z][A-Z0-9]+-\d+)")
FLAKY_KEY = re.compile(r"FLAKY\s+(FL-\d+)")
HELPER_HINT = re.compile(r"/(utils|helpers?|support|fixtures?|pages?|page-objects?)/")
UNFINISHED = {"passed", "skipped"}


def strip_ansi(text):
    return ANSI.sub("", text or "")


def normalize(msg):
    msg = strip_ansi(msg)
    for rx, repl in NORMALIZERS:
        msg = rx.sub(repl, msg)
    return msg.strip()


def first_line(msg):
    for line in normalize(msg).splitlines():
        if line.strip():
            return line.strip()[:200]
    return ""


# ----------------------------------------------------------------- Playwright ---

def walk_suites(suites, titles, out):
    for suite in suites or []:
        path = titles + ([suite.get("title")] if suite.get("title") else [])
        for spec in suite.get("specs") or []:
            for test in spec.get("tests") or []:
                out.append({
                    "file": spec.get("file") or suite.get("file") or "",
                    "line": spec.get("line"),
                    "title": spec.get("title") or "",
                    "title_path": [t for t in path if t and not t.endswith((".ts", ".js", ".tsx", ".jsx"))]
                                  + [spec.get("title") or ""],
                    "project": test.get("projectName") or "",
                    "expected_status": test.get("expectedStatus") or "passed",
                    "outcome": test.get("status") or "",
                    "annotations": test.get("annotations") or [],
                    "results": test.get("results") or [],
                    "tags": spec.get("tags") or [],
                })
        walk_suites(suite.get("suites"), path, out)


def full_title(row):
    parts = [p for p in row["title_path"] if p]
    return " › ".join([row["file"]] + parts) if row["file"] else " › ".join(parts)


def annotation_text(row):
    return " ".join(
        str(a.get("description") or "")
        for a in row["annotations"]
        if a.get("type") in ("fail", "fixme", "skip", "slow", "issue") or a.get("description")
    ).strip()


def last_result(row):
    results = sorted(row["results"], key=lambda r: r.get("retry", 0))
    return results[-1] if results else None


def flaky_hint(row):
    seen_fail = False
    for r in sorted(row["results"], key=lambda r: r.get("retry", 0)):
        st = r.get("status")
        if st in ("failed", "timedOut", "interrupted"):
            seen_fail = True
        elif st == "passed" and seen_fail:
            return True
    return False


def error_text(result):
    parts = []
    err = result.get("error") or {}
    for e in [err] + list(result.get("errors") or []):
        if not e:
            continue
        parts.append(e.get("message") or "")
        parts.append(e.get("stack") or "")
    return "\n".join(p for p in parts if p)


def classify(norm, raw, title_path, result):
    low = norm.lower()
    if re.search(r"\b(before|after)(all|each)\b", low) and "hook" in low:
        return "hook-failure"
    if any(re.search(r"\b(before|after)(all|each) hook\b", t or "", re.I) for t in title_path):
        return "hook-failure"
    if "strict mode violation" in low:
        return "strict-mode"
    if AUTH_URL.search(raw) and ("tohaveurl" in low or "redirect" in low or "login" in low):
        return "auth-redirect"
    if ("page.goto" in low or "navigation" in low) and ("timeout" in low or "timed out" in low):
        return "navigation-timeout"
    if NET_ERR.search(raw) or re.search(r"\b5\d\d\b", norm) and ENDPOINT.search(raw):
        return "network"
    if ("timeout" in low or "timed out" in low) and ("locator" in low or "waiting for" in low or "getby" in low):
        return "locator-timeout"
    if "expected" in low and "received" in low:
        return "assertion-mismatch"
    if result.get("status") == "timedOut":
        return "locator-timeout" if "locator" in low else "navigation-timeout"
    return "unknown"


def pick_frames(stack, spec_dir):
    """Return (helper_key, spec_key) from a stack: frames under spec_dir only."""
    helper, spec = None, None
    for m in FRAME.finditer(stack or ""):
        path, line = m.group(1), m.group(2)
        if "node_modules" in path or not line:
            continue
        rel = path
        idx = rel.find("/" + spec_dir.strip("/") + "/") if spec_dir else -1
        if spec_dir:
            if idx == -1 and not rel.startswith(spec_dir.strip("/") + "/"):
                continue
            rel = rel[idx + 1:] if idx != -1 else rel
        key = "%s:%s" % (rel, line)
        if HELPER_HINT.search("/" + rel) and helper is None:
            helper = key
        elif spec is None:
            spec = key
    return helper, spec


def infer_spec_dir(rows):
    for row in rows:
        f = row.get("file") or ""
        if "/" in f:
            return f.split("/")[0]
    return ""


def analyse(row, spec_dir):
    result = last_result(row) or {}
    # prefer the first FAILED result's error — the last may be a passing retry
    failing = [r for r in sorted(row["results"], key=lambda r: r.get("retry", 0))
               if r.get("status") not in UNFINISHED]
    err_result = failing[0] if failing else result
    raw = strip_ansi(error_text(err_result))
    norm = normalize(raw)
    sel = SELECTOR.search(raw)
    helper_key, spec_key = pick_frames(raw, spec_dir)
    if not spec_key and err_result.get("errorLocation"):
        loc = err_result["errorLocation"]
        spec_key = "%s:%s" % (loc.get("file", row["file"]), loc.get("line", ""))
    ep = ENDPOINT.search(raw)
    endpoint = None
    if ep:
        path = re.sub(r"^https?://[^/]+", "", ep.group(2))
        endpoint = "%s %s" % (ep.group(1), path.split("?")[0])
    status = HTTP_STATUS.search(raw)
    net = NET_ERR.search(raw)
    attachments = [a.get("path") for a in (result.get("attachments") or []) if a.get("path")]
    return {
        "id": full_title(row),
        "file": row["file"],
        "line": row["line"],
        "title": row["title"],
        "project": row["project"],
        "tags": row["tags"],
        "status": result.get("status"),
        "retries": len(row["results"]) - 1 if row["results"] else 0,
        "flaky_hint": flaky_hint(row),
        "error_class": classify(norm, raw, row["title_path"], err_result),
        "message": first_line(raw),
        "selector": sel.group(1) if sel else None,
        "helper_frame": helper_key,
        "spec_frame": spec_key,
        "endpoint": endpoint,
        "http_status": status.group(1) if status else None,
        "net_error": net.group(0) if net else None,
        "attachments": attachments,
    }


# ------------------------------------------------------------------ newman ---

def newman_rows(doc):
    """newman JSON export -> same row shape as analyse(). One row per failed assertion."""
    run = doc.get("run") or {}
    coll = ((doc.get("collection") or {}).get("info") or {}).get("name") or "collection"
    rows = []
    for ex in run.get("executions") or []:
        item = (ex.get("item") or {}).get("name") or "request"
        req = ex.get("request") or {}
        url = req.get("url") or {}
        if isinstance(url, dict):
            path = "/" + "/".join(str(p) for p in (url.get("path") or []))
        else:
            path = re.sub(r"^https?://[^/]+", "", str(url))
        method = req.get("method") or "GET"
        code = (ex.get("response") or {}).get("code")
        for a in ex.get("assertions") or []:
            err = a.get("error")
            if not err:
                continue
            msg = normalize(err.get("message") or err.get("name") or "")
            rows.append({
                "id": "%s › %s › %s" % (coll, item, a.get("assertion") or "assertion"),
                "file": coll,
                "line": None,
                "title": "%s › %s" % (item, a.get("assertion") or "assertion"),
                "project": "newman",
                "tags": [],
                "status": "failed",
                "retries": 0,
                "flaky_hint": False,
                "error_class": "network" if code and code >= 500 else "assertion-mismatch",
                "message": msg[:200],
                "selector": None,
                "helper_frame": None,
                "spec_frame": None,
                "endpoint": "%s %s" % (method, path.split("?")[0]),
                "http_status": str(code) if code else None,
                "net_error": None,
                "attachments": [],
            })
    stats = (run.get("stats") or {}).get("assertions") or {}
    totals = {
        "passed": max(0, int(stats.get("total", 0)) - int(stats.get("failed", 0))),
        "failed": int(stats.get("failed", len(rows))),
        "known_failures_with_bug": 0,
        "known_failures_unkeyed": 0,
        "skipped": 0,
    }
    return rows, totals


# -------------------------------------------------------------- clustering ---

class UnionFind:
    def __init__(self, n):
        self.p = list(range(n))

    def find(self, i):
        while self.p[i] != i:
            self.p[i] = self.p[self.p[i]]
            i = self.p[i]
        return i

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra != rb:
            self.p[max(ra, rb)] = min(ra, rb)


def cluster(rows):
    uf = UnionFind(len(rows))
    by_key = {}

    def link(level, key, i):
        if key is None:
            return
        k = (level, key)
        if k in by_key:
            uf.union(by_key[k], i)
        else:
            by_key[k] = i

    for i, r in enumerate(rows):
        link("K1", r["helper_frame"], i)
        link("K2", r["selector"], i)
        if r["endpoint"]:
            link("K3", (r["error_class"], r["endpoint"], r["http_status"]), i)
    for i, r in enumerate(rows):
        if not (r["helper_frame"] or r["selector"] or r["endpoint"]):
            link("K4", (r["error_class"], r["file"]), i)

    groups = OrderedDict()
    for i in range(len(rows)):
        groups.setdefault(uf.find(i), []).append(rows[i])

    clusters = []
    for members in groups.values():
        level, key = shared_key(members)
        classes = sorted({m["error_class"] for m in members})
        clusters.append({
            "size": len(members),
            "key_level": level,
            "key": key,
            "error_classes": classes,
            "class_hint": class_hint(members),
            "representative": min(members, key=lambda m: (len(m["title"]), m["title"]))["id"],
            "flaky_ratio": round(sum(1 for m in members if m["flaky_hint"]) / len(members), 2),
            "files": sorted({m["file"] for m in members}),
            "attachments": sorted({a for m in members for a in m["attachments"]}),
            "tests": [m["id"] for m in members],
            "members": members,
        })
    clusters.sort(key=lambda c: (-c["size"], c["representative"]))
    for n, c in enumerate(clusters, 1):
        c["id"] = "C%d" % n
    return clusters


def shared_key(members):
    for level, field in (("K1", "helper_frame"), ("K2", "selector")):
        vals = {m[field] for m in members}
        if len(vals) == 1 and None not in vals:
            return level, vals.pop()
    k3 = {(m["error_class"], m["endpoint"], m["http_status"]) for m in members if m["endpoint"]}
    if len(k3) == 1 and len(members) == sum(1 for m in members if m["endpoint"]):
        ec, ep, st = k3.pop()
        return "K3", "%s %s%s" % (ec, ep, (" -> " + st) if st else "")
    k4 = {(m["error_class"], m["file"]) for m in members}
    if len(k4) == 1:
        ec, f = k4.pop()
        return "K4", "%s in %s" % (ec, f)
    m = members[0]
    return "K4", "%s in %s (mixed)" % (m["error_class"], m["file"])


def class_hint(members):
    if sum(1 for m in members if m["flaky_hint"]) / len(members) >= 0.5:
        return "flaky"
    classes = {m["error_class"] for m in members}
    statuses = {m["http_status"] for m in members if m["http_status"]}
    if classes & {"network", "navigation-timeout", "auth-redirect"} or any(s.startswith("5") for s in statuses):
        return "env-or-data"
    if classes & {"strict-mode", "locator-timeout", "hook-failure"}:
        return "broken-test"
    if "assertion-mismatch" in classes:
        return "bug-or-copy-drift"
    return "unclassified"


# ----------------------------------------------------------- known failures ---

def known_failures(rows, key_rx):
    known, violations = [], []
    for row in rows:
        if row["expected_status"] != "failed":
            continue
        text = annotation_text(row)
        m = key_rx.search(text)
        last = last_result(row) or {}
        fl = FLAKY_KEY.search(text)
        entry = {
            "id": full_title(row),
            "file": row["file"],
            "line": row["line"],
            "annotation": text,
            "bug_key": m.group(1) if m else None,
            "flaky_key": fl.group(1) if fl else None,
            "last_status": last.get("status"),
            "now_passing": last.get("status") == "passed",
        }
        known.append(entry)
        if not entry["bug_key"]:
            violations.append({"id": entry["id"], "file": row["file"], "line": row["line"],
                               "reason": "test.fail without a BUG <KEY>-<n> key",
                               "annotation": text})
    return known, violations


# ----------------------------------------------------------------- summary ---

def summarize(rows, failing, known):
    passed = skipped = 0
    for row in rows:
        if row["expected_status"] == "failed":
            continue
        last = last_result(row) or {}
        st = last.get("status")
        if st == "skipped" or row["expected_status"] == "skipped":
            skipped += 1
        elif st == "passed" and not flaky_hint(row):
            passed += 1
    keyed = sum(1 for k in known if k["bug_key"] is not None)
    return {
        "passed": passed,
        "failed": len(failing),
        "known_failures_with_bug": keyed,
        "known_failures_unkeyed": len(known) - keyed,
        "skipped": skipped,
        "flaky": sum(1 for f in failing if f["flaky_hint"]),
    }


def four_numbers(summary):
    line = ("passed=%d failed=%d known-failures-with-bug=%d skipped=%d known-failures-unkeyed=%d"
            % (summary["passed"], summary["failed"], summary["known_failures_with_bug"], summary["skipped"],
               summary.get("known_failures_unkeyed", 0)))
    if summary.get("flaky"):
        line += " (of failed, flaky=%d)" % summary["flaky"]
    return line


def render_md(summary, clusters, known, violations, source):
    out = ["# Triage clusters", "", "Source: `%s`" % source, "",
           "**%s**" % four_numbers(summary), "",
           "Known failures with bug: %d · unkeyed (violations): %d"
           % (summary["known_failures_with_bug"], summary.get("known_failures_unkeyed", 0)), "",
           "Known failures are expected-fail tests. They are NOT passes and are listed separately below. "
           "An unkeyed one (`test.fail` without a `BUG <KEY>-<n>` key) is a violation and is counted "
           "neither as a pass nor as a known failure with bug.", ""]
    out += ["## Clusters (largest first)", "",
            "| id | size | key | classes | hint | representative |",
            "|---|---|---|---|---|---|"]
    for c in clusters:
        out.append("| %s | %d | %s `%s` | %s | %s | %s |" % (
            c["id"], c["size"], c["key_level"], c["key"].replace("|", "\\|"),
            ", ".join(c["error_classes"]), c["class_hint"], c["representative"].replace("|", "\\|")))
    if not clusters:
        out.append("| — | 0 | no failing tests | | | |")
    out.append("")
    for c in clusters:
        out += ["### %s — %d test(s) — %s" % (c["id"], c["size"], c["class_hint"]), "",
                "- key: %s `%s`" % (c["key_level"], c["key"]),
                "- files: %s" % ", ".join("`%s`" % f for f in c["files"])]
        for m in c["members"]:
            flag = " (flaky: passed on retry)" if m["flaky_hint"] else ""
            out.append("  - %s — %s%s" % (m["id"], m["message"] or m["error_class"], flag))
        if c["attachments"]:
            out.append("- attachments:")
            out += ["  - `%s`" % a for a in c["attachments"]]
        out.append("")
    out += ["## Known failures with bug (expected-fail, not passes)", ""]
    if known:
        out += ["| test | bug | last result | annotation |", "|---|---|---|---|"]
        for k in known:
            tail = " — **now passing: remove test.fail**" if k["now_passing"] else ""
            out.append("| %s | %s | %s%s | %s |" % (
                k["id"].replace("|", "\\|"), k["bug_key"] or "**none**", k["last_status"] or "—", tail,
                (k["annotation"] or "").replace("|", "\\|")))
    else:
        out.append("none")
    out += ["", "## Violations", ""]
    if violations:
        out += ["| test | reason | annotation |", "|---|---|---|"]
        for v in violations:
            out.append("| %s | %s | %s |" % (v["id"].replace("|", "\\|"), v["reason"],
                                            (v["annotation"] or "").replace("|", "\\|")))
    else:
        out.append("none")
    out.append("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description="Cluster a Playwright (or newman) JSON report into failure causes.")
    ap.add_argument("report")
    ap.add_argument("--out", help="clusters.json path (default: next to the report)")
    ap.add_argument("--md", help="clusters.md path (default: next to the report)")
    ap.add_argument("--spec-dir", default="", help="spec dir used to pick helper/spec frames (inferred if omitted)")
    ap.add_argument("--key-pattern", default="[A-Z][A-Z0-9]+",
                    help="regex for the accepted bug-key project prefix, e.g. PROJ")
    ap.add_argument("--newman", action="store_true", help="input is a newman JSON export")
    args = ap.parse_args()

    report = Path(args.report)
    try:
        doc = json.loads(report.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print("ERROR: cannot read %s: %s" % (report, exc), file=sys.stderr)
        return 1

    key_rx = re.compile(r"BUG\s+((?:%s)-\d+)" % args.key_pattern)
    if args.newman:
        failing, summary = newman_rows(doc)
        known, violations = [], []
    else:
        rows = []
        walk_suites(doc.get("suites"), [], rows)
        spec_dir = args.spec_dir or infer_spec_dir(rows)
        known, violations = known_failures(rows, key_rx)
        candidates = [r for r in rows if r["expected_status"] != "failed"
                      and any((res.get("status") not in UNFINISHED) for res in r["results"])]
        failing = [analyse(r, spec_dir) for r in candidates]
        summary = summarize(rows, failing, known)
    summary["violations"] = len(violations)

    clusters = cluster(failing)
    out_json = Path(args.out) if args.out else report.with_name("clusters.json")
    out_md = Path(args.md) if args.md else report.with_name("clusters.md")
    payload = {"source": str(report), "summary": summary, "clusters": clusters,
               "known_failures": known, "violations": violations}
    out_json.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    out_md.write_text(render_md(summary, clusters, known, violations, str(report)), encoding="utf-8")

    print(four_numbers(summary))
    print("clusters=%d violations=%d -> %s, %s" % (len(clusters), len(violations), out_json, out_md))
    for c in clusters:
        print("  %s size=%d %s %s [%s] %s" % (c["id"], c["size"], c["key_level"], c["key"], c["class_hint"], c["representative"]))
    for v in violations:
        print("  VIOLATION %s — %s" % (v["id"], v["reason"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
