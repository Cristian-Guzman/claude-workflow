#!/usr/bin/env python3
"""
harvest-profile.py — emit a SANITIZED, aggregates-only profile of a mature workflow install.

Run on the confidential machine. Reads the workspace .claude/ tree (and optionally the
product repos under it), computes shapes and counts — never content — and writes
profile.json + profile.md that are safe to carry to the public workflow repo.

What leaves: structure stats of pattern/testing files, selector-strategy and skip
frequencies, spec/helper/page-object counts, Playwright config shape (no URLs),
CI aggregates keyed by sha256-hashed workflow names, state-index kind/status counts,
cycle-time aggregates, proposal status/age/target histograms, capability enums, agent
override names + tool lists, and per-file drift line counts against --public-core.
Every emitted field is documented in core/docs/profile.schema.md.

What never leaves: file contents, entry text, ticket keys, branch names, URLs, paths,
people, run titles. Free-text strings (section titles, agent names, class labels) pass
through the sanitizer rules of upstream.py; whatever still trips `upstream.py check`
becomes <redacted-title-N>; if a single hit survives that, NOTHING is written.

Usage:
  harvest-profile.py --workspace <.claude dir> --config <upstream.json> --out <dir>
                     [--repos <path> ...] [--ci-runs runs.json] [--public-core <dir>]
                     [--dry-run] [--max-redaction-rounds N]

  --ci-runs     output of: gh run list --limit 500 --json conclusion,name,workflowName,headBranch,headSha,attempt,createdAt,event
  --public-core the public repo's core/ dir (or a .upstream-base/ snapshot) for drift counts

Exit codes: 0 written clean · 1 usage/config error · 2 leak check failed, nothing written.
"""
import argparse
import contextlib
import difflib
import hashlib
import importlib.util
import io
import json
import re
import shutil
import statistics
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 1
HERE = Path(__file__).resolve().parent
TITLE_KEYS = {"h2_titles", "project_names", "class_labels", "surfaces", "statuses", "name", "names",
              "local_only", "targets", "reporters", "decisions", "distinct_statuses", "label"}

H2_RX = re.compile(r"^## (.+?)\s*$", re.M)
H3_RX = re.compile(r"^### (.+?)\s*$", re.M)
TAG_RX = re.compile(r"^### \[([^\]]+)\]", re.M)
SOURCE_RX = re.compile(r"^(?:_Source:|- \*\*Source\*\*:|Provenance:|_Learned from:)\s*(.+)$", re.M | re.I)
LAST_RUN_RX = re.compile(r"^<!-- (?:last|prev)-run:", re.M)
INDEX_LINE_RX = re.compile(r"^- \[", re.M)
PROPOSAL_RX = re.compile(r"^### \[(\d{4}-\d{2}-\d{2})\]", re.M)
PROCESS_LOG_RX = re.compile(
    r"class=(\S+) sessions=(\d+) phases=(\d+) fix_iter=(\d+) debug=(\S+) days=(\d+)")
META_LESSON_RX = re.compile(r"^### \[surface=([^\s·\]]+)\s*·\s*cluster=([^\]]+)\]", re.M)
TEST_CALL_RX = re.compile(r"\b(?:test|it)(?:\.(?:skip|fixme|only|fail))?\(")
SELECTOR_PATTERNS = {
    "getByRole": r"getByRole\(", "getByLabel": r"getByLabel\(", "getByTestId": r"getByTestId\(",
    "getByText": r"getByText\(", "getByPlaceholder": r"getByPlaceholder\(", "getByTitle": r"getByTitle\(",
    "getByAltText": r"getByAltText\(", "locator": r"\.locator\(",
    "locator_class_contains": r"locator\(\s*['\"]\[class\*=", "css_id_selector": r"locator\(\s*['\"]#",
    "xpath": r"locator\(\s*['\"]//|xpath=", "waitForTimeout": r"waitForTimeout\(",
    "networkidle": r"networkidle",
}
GUARD_PATTERNS = {
    "test_skip": r"\b(?:test|it|describe)\.skip\(", "test_fixme": r"\b(?:test|it|describe)\.fixme\(",
    "test_only": r"\b(?:test|it|describe)\.only\(", "test_fail": r"\btest\.fail\(",
    "soft_guard": r"isVisible\(\)\s*\.catch\(\s*\(\s*\)\s*=>\s*false\s*\)",
    "skip_with_key": r"\.(?:skip|fixme|fail)\([^)]*(?:BUG|FLAKY)\s+[A-Z]+-\d+",
}
REPORTERS = ("html", "list", "line", "dot", "json", "junit", "github", "blob", "null")
CORE_MAP = {"commands": "commands", "agents": "agents", "scripts": "scripts", "docs": "."}
PROJECT_OWNED_ROOT = {"codebase-patterns.md", "testing-patterns.md", "ticket-checklist.md", "pr-template.md",
                      "business-context.md", "stack-connections.md", "project-map.md", "command-proposals.md",
                      "capability-manifest.md", "CLAUDE.md", "README.md"}


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_upstream():
    spec = importlib.util.spec_from_file_location("upstream", HERE / "upstream.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def read(p):
    try:
        return Path(p).read_text(errors="replace")
    except OSError:
        return ""


def sha12(text):
    return hashlib.sha256(text.encode()).hexdigest()[:12]


def stats(values):
    vals = [v for v in values if v is not None]
    if not vals:
        return {"n": 0}
    vals.sort()
    p90 = vals[min(len(vals) - 1, int(round(0.9 * (len(vals) - 1))))]
    return {"n": len(vals), "mean": round(statistics.mean(vals), 2), "median": statistics.median(vals),
            "p90": p90, "max": max(vals)}


def histogram(items):
    out = {}
    for it in items:
        out[it] = out.get(it, 0) + 1
    return dict(sorted(out.items(), key=lambda kv: (-kv[1], kv[0])))


def hist_list(items, key="label"):
    return [{key: k, "n": v} for k, v in histogram(items).items()]


def count_rx(rx, text):
    return len(re.findall(rx, text))


# ---------------------------------------------------------------- markdown structure
def md_structure(text):
    lines = text.splitlines()
    h2s = H2_RX.findall(text)
    heading_idx = [i for i, ln in enumerate(lines) if ln.startswith("## ") or ln.startswith("### ")]
    entry_lens = []
    for pos, i in enumerate(heading_idx):
        if not lines[i].startswith("### "):
            continue
        end = heading_idx[pos + 1] if pos + 1 < len(heading_idx) else len(lines)
        body = [ln for ln in lines[i:end] if ln.strip()]
        entry_lens.append(len(body))
    sources = SOURCE_RX.findall(text)
    mix = {"ticket": 0, "session": 0, "code_observation": 0, "mined": 0, "seed_pack": 0, "other": 0}
    for s in sources:
        s_low = s.lower()
        if "[[" in s or re.search(r"\b[A-Z]{2,6}-\d+\b", s):
            mix["ticket"] += 1
        elif "session" in s_low:
            mix["session"] += 1
        elif "code-observation" in s_low or "code observation" in s_low:
            mix["code_observation"] += 1
        elif "mined:" in s_low:
            mix["mined"] += 1
        elif "seed-pack:" in s_low:
            mix["seed_pack"] += 1
        else:
            mix["other"] += 1
    idx_lines = 0
    m = re.search(r"^## Index\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    if m:
        idx_lines = len(INDEX_LINE_RX.findall(m.group(1)))
    h3 = len(H3_RX.findall(text))
    return {
        "lines": len(lines),
        "h2": len(h2s),
        "h3": h3,
        "h2_titles": h2s,
        "entry_lines": stats(entry_lens),
        "entries_le_8_lines": sum(1 for n in entry_lens if n <= 8),
        "tags": histogram(TAG_RX.findall(text)),
        "source_mix": mix,
        "index_lines": idx_lines,
        "index_coverage": round(idx_lines / h3, 2) if h3 else None,
        "last_run_lines": len(LAST_RUN_RX.findall(text)),
        "code_blocks": text.count("```") // 2,
        "has_shared_pointer": "patterns-shared.md" in text,
        "has_comment_hygiene_h2": "## Code comment hygiene" in text,
        "has_lessons_learned_h2": "## Lessons Learned" in text,
        "has_seed_banner": "Seed file" in text,
    }


def testing_structure(text):
    base = md_structure(text)
    base.update({
        "has_e2e_repo_awareness_h2": "## E2E repo-awareness" in text,
        "has_e2e_drift_taxonomy_h2": "## E2E drift taxonomy" in text,
        "has_e2e_suite_health_h2": "## E2E suite health" in text,
        "suite_health_stamps": text.count("<!-- e2e-suite-health"),
    })
    return base


# ---------------------------------------------------------------- repo profile yaml (flat subset)
def parse_profile_yaml(text):
    out, nested = {}, None
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        line = raw.split(" #", 1)[0].rstrip()
        if not line.startswith(" "):
            key, _, val = line.partition(":")
            nested = key.strip() if val.strip() == "" else None
            out[key.strip()] = val.strip().strip('"').strip("'")
        elif nested and line.startswith("  ") and not line.startswith("    "):
            key, _, val = line.strip().partition(":")
            out[f"{nested}.{key.strip()}"] = val.strip().strip('"').strip("'")
    return out


def is_default_branch(name):
    return name in ("main", "master", "develop", "trunk")


# ---------------------------------------------------------------- e2e suite shape
def find_spec_dir(repo, profile):
    cand = profile.get("e2e.spec_dir", "")
    if cand and (repo / cand).is_dir():
        return repo / cand
    for cfg in ("playwright.config.ts", "playwright.config.js", "playwright.config.mjs"):
        p = repo / cfg
        if p.exists():
            m = re.search(r"testDir:\s*['\"]([^'\"]+)['\"]", read(p))
            if m and (repo / m.group(1)).is_dir():
                return repo / m.group(1)
    for d in ("e2e", "tests/e2e", "test/e2e", "playwright"):
        if (repo / d).is_dir():
            return repo / d
    return None


def e2e_shape(repo, profile):
    spec_dir = find_spec_dir(repo, profile)
    if not spec_dir:
        return {"present": False}
    files = [p for p in spec_dir.rglob("*") if p.is_file() and "node_modules" not in p.parts
             and p.suffix in (".ts", ".tsx", ".js", ".mjs")]
    specs = [p for p in files if re.search(r"\.spec\.(?:ts|tsx|js|mjs)$", p.name)]
    helpers = [p for p in files if p not in specs and not p.name.endswith(".setup.ts")]
    page_objects = [p for p in helpers if re.search(r"(?:^|/)(?:pages?|page-objects?|pom)/", p.as_posix())
                    or re.search(r"(?:\.page\.|Page\.|\.po\.)", p.name)]
    fixtures = [p for p in helpers if re.search(r"(?:^|/)(?:__)?fixtures?(?:__)?/", p.as_posix())]
    setups = [p for p in files if p.name.endswith(".setup.ts")]
    text = "\n".join(read(p) for p in specs)
    total_tests = count_rx(TEST_CALL_RX, text)
    selectors = {k: count_rx(v, text) for k, v in SELECTOR_PATTERNS.items()}
    guards = {k: count_rx(v, text) for k, v in GUARD_PATTERNS.items()}
    density = {k: (round(v / total_tests * 100, 2) if total_tests else None) for k, v in guards.items()}
    sel_total = sum(v for k, v in selectors.items() if k.startswith("getBy") or k == "locator")
    return {
        "present": True,
        "spec_dir_depth": len(spec_dir.relative_to(repo).parts),
        "spec_files": len(specs), "helper_files": len(helpers), "page_object_files": len(page_objects),
        "fixture_files": len(fixtures), "setup_files": len(setups),
        "tests_total": total_tests, "describe_blocks": count_rx(r"\btest\.describe\(", text),
        "selectors": selectors,
        "selector_share": {k: (round(v / sel_total, 3) if sel_total else None) for k, v in selectors.items()
                           if k.startswith("getBy") or k == "locator"},
        "guards": guards, "guard_density_per_100_tests": density,
    }


def parse_env_ternary(expr):
    expr = expr.strip().rstrip(",")
    m = re.match(r"process\.env\.\w+\s*\?\s*(\d+|undefined)\s*:\s*(\d+|undefined)$", expr)
    if m:
        conv = lambda s: None if s == "undefined" else int(s)
        return {"ci": conv(m.group(1)), "local": conv(m.group(2))}
    if re.match(r"^\d+$", expr):
        return {"all": int(expr)}
    if expr == "undefined":
        return {"all": None}
    return "expression"


def playwright_shape(repo):
    for cfg in ("playwright.config.ts", "playwright.config.js", "playwright.config.mjs"):
        p = repo / cfg
        if not p.exists():
            continue
        t = read(p)
        body = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
        body = re.sub(r"^\s*//.*$", "", body, flags=re.M)
        retries = re.search(r"\bretries:\s*([^\n]+)", body)
        workers = re.search(r"\bworkers:\s*([^\n]+)", body)
        rep = re.search(r"\breporter:\s*([\s\S]{0,400})", body)
        reporters = sorted({r for r in REPORTERS if rep and re.search(r"['\"]" + r + r"['\"]", rep.group(1))})
        proj = re.search(r"\bprojects:\s*\[([\s\S]*?)\n\s*\],?", body)
        project_names = re.findall(r"\bname:\s*['\"]([^'\"]+)['\"]", proj.group(1)) if proj else []
        trace = re.search(r"\btrace:\s*['\"]([a-z-]+)['\"]", body)
        shot = re.search(r"\bscreenshot:\s*['\"]([a-z-]+)['\"]", body)
        video = re.search(r"\bvideo:\s*['\"]([a-z-]+)['\"]", body)
        timeout = re.search(r"^\s*timeout:\s*(\d[\d_]*)", body, re.M)
        return {
            "present": True, "ext": p.suffix.lstrip("."),
            "retries": parse_env_ternary(retries.group(1)) if retries else None,
            "workers": parse_env_ternary(workers.group(1)) if workers else None,
            "reporters": reporters,
            "reporter_is_env_conditional": bool(rep and "process.env" in rep.group(1)[:80]),
            "projects": len(project_names), "project_names": project_names,
            "trace": trace.group(1) if trace else None,
            "screenshot": shot.group(1) if shot else None,
            "video": video.group(1) if video else None,
            "timeout_ms": int(timeout.group(1).replace("_", "")) if timeout else None,
            "fully_parallel": "fullyParallel: true" in body,
            "forbid_only": "forbidOnly:" in body,
            "has_base_url": "baseURL" in body,
            "has_web_server": "webServer" in body,
            "has_global_setup": "globalSetup" in body,
            "has_storage_state": "storageState" in body,
        }
    return {"present": False}


# ---------------------------------------------------------------- agents
def agent_shape(path):
    fm = read(path)
    m = re.search(r"^---\s*$(.*?)^---\s*$", fm, re.M | re.S)
    front = m.group(1) if m else ""
    name = re.search(r"^name:\s*(.+)$", front, re.M)
    tools = re.search(r"^tools:\s*(.+)$", front, re.M)
    model = re.search(r"^model:\s*(.+)$", front, re.M)
    return {
        "name": (name.group(1).strip() if name else path.stem),
        "tools": [t.strip() for t in tools.group(1).split(",")] if tools else [],
        "model": model.group(1).strip() if model else None,
        "lines": len(fm.splitlines()),
    }


# ---------------------------------------------------------------- ledgers
def process_ledger(text):
    rows = PROCESS_LOG_RX.findall(text)
    by_class = {}
    for cls, sess, ph, fix, dbg, days in rows:
        b = by_class.setdefault(cls, {"n": 0, "sessions": [], "phases": [], "fix_iter": [], "days": [], "with_debug": 0})
        b["n"] += 1
        b["sessions"].append(int(sess)); b["phases"].append(int(ph)); b["fix_iter"].append(int(fix)); b["days"].append(int(days))
        b["with_debug"] += 0 if dbg == "none" else 1
    classes = []
    for cls, b in sorted(by_class.items(), key=lambda kv: -kv[1]["n"]):
        classes.append({"label": cls, "n": b["n"], "with_debug": b["with_debug"],
                        "mean_sessions": round(statistics.mean(b["sessions"]), 2),
                        "mean_phases": round(statistics.mean(b["phases"]), 2),
                        "mean_fix_iter": round(statistics.mean(b["fix_iter"]), 2),
                        "mean_days": round(statistics.mean(b["days"]), 2)})
    lessons_sec = re.search(r"## AUTO:PROCESS-LESSONS(.*?)(?=^## |\Z)", text, re.M | re.S)
    return {"present": True, "log_rows": len(rows), "classes": classes,
            "lessons_h3": len(H3_RX.findall(lessons_sec.group(1))) if lessons_sec else 0,
            "lessons_bullets": len(re.findall(r"^- \*\*", lessons_sec.group(1), re.M)) if lessons_sec else 0}


def ui_ledger(text):
    pairs = META_LESSON_RX.findall(text)
    return {"present": True, "meta_lessons": len(pairs),
            "surfaces": hist_list([s for s, _ in pairs]),
            "clusters": histogram([c.strip() for _, c in pairs]),
            "kpi_stamps": text.count("<!-- ui-iteration-kpi")}


# ---------------------------------------------------------------- workspace-level
def state_index(ws, alias_of):
    p = ws / "state" / "index.json"
    if not p.exists():
        return {"present": False}
    try:
        data = json.loads(read(p))
    except json.JSONDecodeError:
        return {"present": True, "error": "unparseable"}
    entries = data.get("entries", [])
    cycle_days, by_kind_days, suffixes = [], {}, []
    for e in entries:
        c, u = e.get("created"), e.get("updated")
        if e.get("status") in ("delivered", "learned") and c and u:
            try:
                d = (datetime.fromisoformat(u.replace("Z", "+00:00")) - datetime.fromisoformat(c.replace("Z", "+00:00"))).total_seconds() / 86400
                cycle_days.append(round(d, 2))
                by_kind_days.setdefault((e.get("tags") or {}).get("kind", "untagged"), []).append(round(d, 2))
            except ValueError:
                pass
        key = e.get("key") or ""
        m = re.match(r"^[A-Z]{2,6}-\d+(.*)$", key)
        if m:
            suffixes.append(m.group(1) or "(none)")
        else:
            suffixes.append("slug")
    return {
        "present": True, "version": data.get("version"), "entries": len(entries),
        "by_kind": histogram(e.get("kind", "?") for e in entries),
        "by_status": histogram(e.get("status", "?") for e in entries),
        "archived": sum(1 for e in entries if e.get("archived")),
        "with_pr": sum(1 for e in entries if e.get("pr")),
        "by_repo_alias": histogram(alias_of(e.get("repo", "")) for e in entries),
        "tags_layer": histogram((e.get("tags") or {}).get("layer", "untagged") for e in entries),
        "tags_kind": histogram((e.get("tags") or {}).get("kind", "untagged") for e in entries),
        "tagged_by": histogram(e.get("tagged_by", "none") for e in entries),
        "tag_confidence": histogram(e.get("tag_confidence", "none") for e in entries),
        "key_suffixes": histogram(suffixes),
        "cycle_time_days_created_to_last_update": stats(cycle_days),
        "cycle_time_by_tag_kind": {k: stats(v) for k, v in sorted(by_kind_days.items())},
    }


def proposals(ws, today, known_targets):
    p = ws / "command-proposals.md"
    if not p.exists():
        return {"present": False}
    text = read(p)
    starts = [(m.start(), m.group(1)) for m in PROPOSAL_RX.finditer(text)]
    blocks = []
    for i, (pos, date_s) in enumerate(starts):
        end = starts[i + 1][0] if i + 1 < len(starts) else len(text)
        blocks.append((date_s, text[pos:end]))
    rows, by_status, by_target, occ = [], [], [], []
    for date_s, body in blocks:
        st = re.search(r"\*\*Status:\*\*\s*([A-Z][A-Z-]*)", body)
        status = st.group(1) if st else "NO-STATUS"
        try:
            age = (today - datetime.strptime(date_s, "%Y-%m-%d").date()).days
        except ValueError:
            age = None
        bucket = None if age is None else ("<21d" if age < 21 else "21-90d" if age <= 90 else ">90d")
        tgt = re.search(r"\*\*Target:\*\*\s*`?([a-z0-9-]+)\.md", body)
        target = tgt.group(1) if tgt else "(none)"
        if known_targets and target not in known_targets and target != "(none)":
            target = "other"
        o = re.search(r"\*\*Occurrences:\*\*\s*(\d+)", body)
        occ.append(o.group(1) if o else "1")
        by_status.append(status); by_target.append(target); rows.append((status, bucket))
    return {
        "present": True, "blocks": len(blocks),
        "by_status": histogram(by_status),
        "by_status_and_age": [{"status": s, "age_bucket": b, "n": n}
                              for (s, b), n in sorted(histogram(rows).items(), key=lambda kv: -kv[1])],
        "targets": hist_list(by_target),
        "occurrences": histogram(occ),
        "reviewed_stamps": text.count("**Reviewed:**"),
    }


def capability_manifest(ws):
    p = ws / "capability-manifest.md"
    if not p.exists():
        return {"present": False}
    rows = re.findall(r"^\|\s*/[a-z0-9-]+\s*\|\s*([A-Z][A-Z -]*?)\s*(?:\(|\|)", read(p), re.M)
    return {"present": True, "decisions": histogram(r.strip() for r in rows)}


def settings_shape(ws):
    p = ws / "settings.json"
    out = {"present": p.exists(), "local_present": (ws / "settings.local.json").exists()}
    if not p.exists():
        return out
    try:
        s = json.loads(read(p))
    except json.JSONDecodeError:
        out["error"] = "unparseable"
        return out
    allow = (s.get("permissions") or {}).get("allow") or []
    out.update({
        "permissions_allow": len(allow),
        "permissions_by_tool": histogram(a.split("(", 1)[0] for a in allow),
        "hooks": {ev: len(v) for ev, v in (s.get("hooks") or {}).items()},
        "env_keys": sorted((s.get("env") or {}).keys()),
    })
    return out


def metrics_shape(ws):
    files = sorted((ws / "metrics").glob("[0-9]*.json")) if (ws / "metrics").is_dir() else []
    keys, versions = set(), set()
    for f in files:
        try:
            d = json.loads(read(f))
        except json.JSONDecodeError:
            continue
        versions.add(str(d.get("schema_version")))
        keys.update((d.get("metrics") or {}).keys())
    return {"snapshots": len(files), "schema_versions": sorted(versions), "metric_keys": sorted(keys),
            "span_days": (len(files) and (datetime.strptime(files[-1].stem[:10], "%Y-%m-%d") -
                                          datetime.strptime(files[0].stem[:10], "%Y-%m-%d")).days) or 0}


def schema_drift(ws):
    p = ws / "state" / "schema-drift.log"
    if not p.exists():
        return {"present": False}
    text = read(p)
    return {"present": True, "lines": len(text.splitlines()),
            "distinct_statuses": hist_list(re.findall(r"non-schema status '([^']+)'", text))}


def ci_aggregates(path):
    try:
        runs = json.loads(read(path))
    except (json.JSONDecodeError, OSError):
        return {"present": True, "error": "unparseable"}
    per = {}
    for r in runs:
        wf = sha12(str(r.get("workflowName") or r.get("name") or ""))
        b = per.setdefault(wf, {"runs": 0, "conclusions": [], "reruns": 0, "events": [], "shas": {}, "branches": set(), "dates": []})
        b["runs"] += 1
        concl = r.get("conclusion") or "none"
        b["conclusions"].append(concl)
        if (r.get("attempt") or 1) > 1:
            b["reruns"] += 1
        b["events"].append(r.get("event") or "?")
        b["shas"].setdefault(r.get("headSha") or "", set()).add(concl)
        b["branches"].add(r.get("headBranch") or "")
        if r.get("createdAt"):
            b["dates"].append(r["createdAt"][:10])
    out = {}
    for wf, b in per.items():
        c = histogram(b["conclusions"])
        s, f = c.get("success", 0), c.get("failure", 0)
        out[wf] = {
            "runs": b["runs"], "by_conclusion": c,
            "failure_rate": round(f / (s + f), 3) if (s + f) else None,
            "reruns": b["reruns"],
            "same_sha_flips": sum(1 for v in b["shas"].values() if {"success", "failure"} <= v),
            "events": histogram(b["events"]), "distinct_branches": len(b["branches"]),
            "span_days": (len(b["dates"]) > 1 and (datetime.strptime(max(b["dates"]), "%Y-%m-%d") -
                                                  datetime.strptime(min(b["dates"]), "%Y-%m-%d")).days) or 0,
        }
    return {"present": True, "runs": len(runs), "workflows": len(out),
            "by_workflow_hash": dict(sorted(out.items(), key=lambda kv: -kv[1]["runs"]))}


def drift_vs_public(ws, public_core):
    core = Path(public_core)
    if (core / "core").is_dir():
        core = core / "core"
    files, local_only = [], []
    seen = set()
    for top, dest in CORE_MAP.items():
        src = core / top
        if not src.is_dir():
            continue
        for bp in sorted(src.rglob("*")):
            if not bp.is_file():
                continue
            rel = bp.relative_to(src)
            ip = ws / dest / rel
            seen.add(ip.resolve())
            if not ip.exists():
                files.append({"file": f"{top}/{rel.as_posix()}", "status": "missing"})
                continue
            a, b = read(bp).splitlines(), read(ip).splitlines()
            if a == b:
                continue
            changed = sum(1 for ln in difflib.unified_diff(a, b, lineterm="", n=0) if ln[:1] in "+-" and not ln.startswith(("+++", "---")))
            files.append({"file": f"{top}/{rel.as_posix()}", "status": "modified", "changed_lines": changed,
                          "baseline_lines": len(a), "installed_lines": len(b)})
    for top, dest in CORE_MAP.items():
        d = ws / dest
        if not d.is_dir():
            continue
        for ip in sorted(d.iterdir()):
            if ip.is_file() and ip.resolve() not in seen and not ip.name.startswith("."):
                if dest == "." and (ip.suffix != ".md" or ip.name in PROJECT_OWNED_ROOT):
                    continue
                local_only.append(f"{top}/{ip.name}")
    return {"compared": True, "modified": sum(1 for f in files if f["status"] == "modified"),
            "missing": sum(1 for f in files if f["status"] == "missing"),
            "files": files, "local_only_count": len(local_only), "local_only": local_only}


# ---------------------------------------------------------------- collect
def collect(args, cfg, today):
    ws = Path(args.workspace).resolve()
    if ws.name != ".claude" and (ws / ".claude").is_dir():
        ws = ws / ".claude"
    root = ws.parent
    aliases = {k.lower(): v for k, v in cfg.get("repo_aliases", {}).items()}

    def alias_of(name):
        if not name:
            return "(none)"
        return aliases.get(name.lower()) or f"repo-{sha12(name)[:8]}"

    repo_dirs = [Path(r).resolve() for r in (args.repos or [])]
    if not repo_dirs:
        repo_dirs = sorted(d for d in root.iterdir() if d.is_dir() and (d / ".claude").is_dir() and d.name != ".claude")
    if not repo_dirs and (ws / "codebase-patterns.md").exists():
        repo_dirs = [root]  # single-repo layout: the root IS the product repo

    repos = {}
    enums = {k: [] for k in ("type", "tracker_system", "component_organization", "ui_surface", "e2e_enabled",
                             "e2e_framework", "e2e_sideload_only", "deploy_model", "base_branch_is_default")}
    for rd in repo_dirs:
        alias = "root" if rd == root else alias_of(rd.name)
        c = rd / ".claude"
        prof = parse_profile_yaml(read(ws / "repo-profiles" / f"{rd.name}.yaml"))
        if prof:
            enums["type"].append(prof.get("type") or "(unset)")
            enums["tracker_system"].append(prof.get("tracker_system") or "(unset)")
            enums["component_organization"].append(prof.get("component_organization") or "(unset)")
            enums["ui_surface"].append(prof.get("ui_surface") or "(unset)")
            enums["e2e_enabled"].append(prof.get("e2e.enabled") or "(unset)")
            enums["e2e_framework"].append(prof.get("e2e.framework") or "(unset)")
            enums["e2e_sideload_only"].append(prof.get("e2e.sideload_only") or "(unset)")
            enums["deploy_model"].append(prof.get("deploy.model") or "(unset)")
            enums["base_branch_is_default"].append(str(is_default_branch(prof.get("base_branch", ""))))
        entry = {
            "has_profile": bool(prof),
            "profile_type": prof.get("type") if prof else None,
            "profile_keys_filled": sum(1 for v in prof.values() if v) if prof else 0,
            "claude_dir_files": histogram(("dir:" + p.name) if p.is_dir() else ("ext:" + (p.suffix or "none"))
                                          for p in c.iterdir()) if c.is_dir() else {},
            "state_files": {k: len(list((c / k).glob("*.md"))) for k in ("tickets", "debug", "builds", "refactors", "e2e", "qa")
                            if (c / k).is_dir()},
        }
        cp = c / "codebase-patterns.md"
        entry["codebase_patterns"] = md_structure(read(cp)) if cp.exists() else {"present": False}
        tp = c / "testing-patterns.md"
        entry["testing_patterns"] = testing_structure(read(tp)) if tp.exists() else {"present": False}
        tc = c / "ticket-checklist.md"
        entry["ticket_checklist"] = {"present": tc.exists(), "lines": len(read(tc).splitlines()),
                                     "checkboxes": count_rx(r"(?m)^- \[ \]", read(tc))} if tc.exists() else {"present": False}
        pl = c / "process-ledger.md"
        entry["process_ledger"] = process_ledger(read(pl)) if pl.exists() else {"present": False}
        ul = c / "ui-fidelity-ledger.md"
        entry["ui_fidelity_ledger"] = ui_ledger(read(ul)) if ul.exists() else {"present": False}
        entry["agents"] = [agent_shape(p) for p in sorted((c / "agents").glob("*.md"))] if (c / "agents").is_dir() else []
        entry["hooks"] = len([p for p in (c / "hooks").iterdir() if p.is_file()]) if (c / "hooks").is_dir() else 0
        entry["scripts"] = len([p for p in (c / "scripts").iterdir() if p.is_file()]) if (c / "scripts").is_dir() else 0
        entry["e2e"] = e2e_shape(rd, prof)
        entry["playwright_config"] = playwright_shape(rd)
        repos[alias] = entry

    known_targets = None
    if args.public_core:
        pc = Path(args.public_core)
        cdir = pc / "core" / "commands" if (pc / "core").is_dir() else pc / "commands"
        if cdir.is_dir():
            known_targets = {p.stem for p in cdir.glob("*.md")}
    ws_commands = sorted(p.stem for p in (ws / "commands").glob("*.md")) if (ws / "commands").is_dir() else []
    archived = sorted(p.stem for p in (ws / "_archived-commands").glob("*.md")) if (ws / "_archived-commands").is_dir() else []
    wv = re.search(r"^version:\s*(\S+)", read(ws / "workflow-version.md"), re.M)

    workspace = {
        "layout": "single-repo" if repo_dirs == [root] else "workspace",
        "repos": len(repos),
        "workflow_version": wv.group(1) if wv else None,
        "commands": {"count": len(ws_commands),
                     "in_public_core": sorted(c for c in ws_commands if known_targets and c in known_targets) if known_targets else None,
                     "local_only": sorted(c for c in ws_commands if known_targets and c not in known_targets) if known_targets else None},
        "archived_commands": {"count": len(archived),
                              "in_public_core": sorted(c for c in archived if known_targets and c in known_targets) if known_targets else None},
        "agents": [agent_shape(p) for p in sorted((ws / "agents").glob("*.md"))] if (ws / "agents").is_dir() else [],
        "root_docs_lines": {name: len(read(ws / name).splitlines()) for name in
                            ("business-context.md", "stack-connections.md", "project-map.md", "codebase-patterns-shared.md",
                             "testing-patterns-shared.md", "capability-manifest.md", "routing.md") if (ws / name).exists()},
        "api_reference_files": len(list((ws / "api-reference").glob("*"))) if (ws / "api-reference").is_dir() else 0,
        "repo_profiles": len([p for p in (ws / "repo-profiles").glob("*.yaml") if not p.name.startswith("_")]) if (ws / "repo-profiles").is_dir() else 0,
        "capability_enums": {k: histogram(v) for k, v in enums.items()},
        "capability_manifest": capability_manifest(ws),
        "settings": settings_shape(ws),
        "state_index": state_index(ws, alias_of),
        "proposals": proposals(ws, today, known_targets),
        "metrics": metrics_shape(ws),
        "schema_drift": schema_drift(ws),
        "mine_runs": len(list((ws / "state" / "mine").iterdir())) if (ws / "state" / "mine").is_dir() else 0,
    }
    profile = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": now_iso(),
        "tool": "harvest-profile.py",
        "sanitization": {"denylist_hash": None, "redactions": {}, "redacted_strings": 0, "check": None},
        "workspace": workspace,
        "repos": repos,
        "ci": ci_aggregates(args.ci_runs) if args.ci_runs else {"present": False},
        "drift": drift_vs_public(ws, args.public_core) if args.public_core else {"compared": False},
    }
    return profile, ws


# ---------------------------------------------------------------- sanitize + check
def walk_strings(obj, path="$"):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from walk_strings(v, f"{path}.{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from walk_strings(v, f"{path}[{i}]")
    elif isinstance(obj, str):
        yield path, obj


def set_path(obj, path, value):
    tokens = re.findall(r"\.([^.\[\]]+)|\[(\d+)\]", path[1:])
    cur = obj
    for i, (key, idx) in enumerate(tokens):
        last = i == len(tokens) - 1
        if key:
            if last:
                cur[key] = value
            else:
                cur = cur[key]
        else:
            if last:
                cur[int(idx)] = value
            else:
                cur = cur[int(idx)]


def sanitize_profile(profile, rules, upstream):
    total = {}
    for path, s in list(walk_strings(profile)):
        new, counts = upstream.apply_rules(s, rules)
        for k, v in counts.items():
            total[k] = total.get(k, 0) + v
        if new != s:
            set_path(profile, path, new)
    return total


def run_check(upstream, config, root, paths):
    """upstream.py `check` on the given paths; returns (rc, hit lines)."""
    buf = io.StringIO()
    ns = argparse.Namespace(config=config, root=root, generic=True, paths=[str(p) for p in paths])
    with contextlib.redirect_stdout(buf):
        rc = upstream.cmd_check(ns)
    hits = [ln for ln in buf.getvalue().splitlines() if re.match(r"^.+:\d+: \[[^\]]+\] ", ln)]
    return rc, hits


def check_leaves(profile, upstream, config, root, tmp):
    leaves = list(walk_strings(profile))
    f = Path(tmp) / "leaves.txt"
    f.write_text("\n".join(f"{p}\t{s.replace(chr(10), ' ')}" for p, s in leaves) + "\n")
    rc, hits = run_check(upstream, config, root, [f])
    offending = []
    for h in hits:
        m = re.match(r"^.+?:(\d+): \[([^\]]+)\] (.*)$", h)
        if not m:
            continue
        n = int(m.group(1)) - 1
        if 0 <= n < len(leaves):
            offending.append({"path": leaves[n][0], "rule": m.group(2), "match": m.group(3)})
    return rc, offending


def redact(profile, offending, start):
    n = start
    for o in offending:
        n += 1
        leaf = o["path"].rsplit(".", 1)[-1]
        leaf_key = re.sub(r"\[\d+\]$", "", leaf)
        tag = "redacted-title" if leaf_key in TITLE_KEYS else "redacted"
        set_path(profile, o["path"], f"<{tag}-{n}>")
    return n


# ---------------------------------------------------------------- render
def render_md(p):
    ws, lines = p["workspace"], []
    add = lines.append
    add("# Workflow profile (sanitized aggregates)\n")
    add(f"Generated {p['generated_at']} · schema v{p['schema_version']} · workflow {ws.get('workflow_version') or 'unknown'} · "
        f"layout {ws['layout']} · {ws['repos']} repo(s) · denylist {p['sanitization']['denylist_hash']} · "
        f"redactions {sum(p['sanitization']['redactions'].values())} · redacted strings {p['sanitization']['redacted_strings']}\n")
    add("No file contents, keys, branches, URLs or paths — see core/docs/profile.schema.md for every field.\n")
    add("## Repos\n")
    add("| repo | type | patterns lines/H2/H3 | entry lines mean/med/max | ≤8-line | source mix (ticket/session/code/mined/seed/other) | index cov | testing lines/H3 | e2e specs | tests | skip/fixme/only/soft | agents |")
    add("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for alias, r in p["repos"].items():
        cp, tp, e2 = r["codebase_patterns"], r["testing_patterns"], r["e2e"]
        if cp.get("present") is False:
            cps = "—"; el = "—"; le8 = "—"; mix = "—"; cov = "—"
        else:
            cps = f"{cp['lines']}/{cp['h2']}/{cp['h3']}"
            s = cp["entry_lines"]
            el = f"{s.get('mean', '—')}/{s.get('median', '—')}/{s.get('max', '—')}"
            le8 = f"{cp['entries_le_8_lines']}/{cp['h3']}"
            m = cp["source_mix"]
            mix = "/".join(str(m[k]) for k in ("ticket", "session", "code_observation", "mined", "seed_pack", "other"))
            cov = cp["index_coverage"]
        tps = "—" if tp.get("present") is False else f"{tp['lines']}/{tp['h3']}"
        if e2.get("present"):
            g = e2["guards"]
            e2s, tests, guards = e2["spec_files"], e2["tests_total"], f"{g['test_skip']}/{g['test_fixme']}/{g['test_only']}/{g['soft_guard']}"
        else:
            e2s = tests = guards = "—"
        add(f"| {alias} | {r.get('profile_type') or '—'} | {cps} | {el} | {le8} | {mix} | {cov} | {tps} | {e2s} | {tests} | {guards} | {len(r['agents'])} |")
    add("")
    for alias, r in p["repos"].items():
        if r["e2e"].get("present"):
            sel = r["e2e"]["selectors"]
            add(f"### {alias} — selector strategy\n")
            add("| " + " | ".join(sel.keys()) + " |")
            add("|" + "---|" * len(sel))
            add("| " + " | ".join(str(v) for v in sel.values()) + " |\n")
            pw = r["playwright_config"]
            if pw.get("present"):
                add(f"Playwright: retries `{pw['retries']}` · workers `{pw['workers']}` · reporters {pw['reporters']} · projects {pw['projects']} "
                    f"· trace `{pw['trace']}` · baseURL {'set' if pw['has_base_url'] else 'absent'} · webServer {pw['has_web_server']}\n")
        titles = r["codebase_patterns"].get("h2_titles") or []
        if titles:
            add(f"### {alias} — codebase-patterns H2 topics\n")
            add(", ".join(f"`{t}`" for t in titles) + "\n")
    si = ws["state_index"]
    add("## State index\n")
    if si.get("present"):
        add(f"entries {si['entries']} · by kind {si['by_kind']} · by status {si['by_status']} · archived {si['archived']} · with PR {si['with_pr']}\n")
        add(f"cycle time (created→last update, delivered/learned): {si['cycle_time_days_created_to_last_update']}\n")
        add(f"tags.layer {si['tags_layer']} · tags.kind {si['tags_kind']} · key suffixes {si['key_suffixes']}\n")
    else:
        add("absent\n")
    pr = ws["proposals"]
    add("## Command proposals\n")
    if pr.get("present"):
        add(f"blocks {pr['blocks']} · by status {pr['by_status']} · targets {pr['targets']} · occurrences {pr['occurrences']}\n")
        add("| status | age | n |\n|---|---|---|")
        for row in pr["by_status_and_age"]:
            add(f"| {row['status']} | {row['age_bucket']} | {row['n']} |")
        add("")
    else:
        add("absent\n")
    add("## Capabilities\n")
    add(f"enums {json.dumps(ws['capability_enums'])}\n")
    add(f"commands {ws['commands']} · archived {ws['archived_commands']} · workspace agents {[a['name'] for a in ws['agents']]}\n")
    add(f"settings: allow {ws['settings'].get('permissions_allow')} by tool {ws['settings'].get('permissions_by_tool')} · hooks {ws['settings'].get('hooks')} · env {ws['settings'].get('env_keys')}\n")
    add(f"metrics snapshots {ws['metrics']['snapshots']} over {ws['metrics']['span_days']}d · schema-drift {ws['schema_drift']}\n")
    for alias, r in p["repos"].items():
        pl = r["process_ledger"]
        if pl.get("present"):
            add(f"### {alias} — process ledger\n")
            add("| class | n | with debug | mean sessions | mean phases | mean fix_iter | mean days |\n|---|---|---|---|---|---|---|")
            for c in pl["classes"]:
                add(f"| {c['label']} | {c['n']} | {c['with_debug']} | {c['mean_sessions']} | {c['mean_phases']} | {c['mean_fix_iter']} | {c['mean_days']} |")
            add(f"\nlessons: {pl['lessons_h3']} H3 + {pl['lessons_bullets']} bullets\n")
        if r["agents"]:
            add(f"### {alias} — agent overrides\n")
            for a in r["agents"]:
                add(f"- `{a['name']}` · tools {a['tools'] or '(default)'} · model {a['model'] or '(default)'} · {a['lines']} lines")
            add("")
    ci = p["ci"]
    add("## CI\n")
    if ci.get("present"):
        add(f"runs {ci.get('runs')} · workflows {ci.get('workflows')}\n")
        add("| workflow (sha256[:12]) | runs | failure rate | reruns | same-sha flips | span days |\n|---|---|---|---|---|---|")
        for h, w in (ci.get("by_workflow_hash") or {}).items():
            add(f"| {h} | {w['runs']} | {w['failure_rate']} | {w['reruns']} | {w['same_sha_flips']} | {w['span_days']} |")
        add("")
    else:
        add("not provided (--ci-runs)\n")
    d = p["drift"]
    add("## Drift vs public core\n")
    if d.get("compared"):
        add(f"modified {d['modified']} · missing {d['missing']} · local-only {d['local_only_count']}\n")
        add("| file | status | changed lines |\n|---|---|---|")
        for f in d["files"]:
            add(f"| {f['file']} | {f['status']} | {f.get('changed_lines', '')} |")
        add("")
        if d["local_only"]:
            add("local-only: " + ", ".join(f"`{x}`" for x in d["local_only"]) + "\n")
    else:
        add("not compared (--public-core)\n")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------- pipeline
def harvest(args, upstream=None, today=None):
    """collect → sanitize → check (redact once) → check artifacts → write. Returns an exit code."""
    upstream = upstream or load_upstream()
    today = today or datetime.now(timezone.utc).date()
    cfg = upstream.load_config(args.config)
    profile, ws = collect(args, cfg, today)
    rules = upstream.build_rules(cfg, str(ws))
    profile["sanitization"]["denylist_hash"] = sha12(read(args.config))
    profile["sanitization"]["redactions"] = sanitize_profile(profile, rules, upstream)

    tmp = Path(tempfile.mkdtemp(prefix="harvest-profile."))
    try:
        rc, offending = check_leaves(profile, upstream, args.config, str(ws), tmp)
        rounds, redacted = 0, 0
        while rc != 0 and offending and rounds < args.max_redaction_rounds:
            redacted = redact(profile, offending, redacted)
            rounds += 1
            rc, offending = check_leaves(profile, upstream, args.config, str(ws), tmp)
        profile["sanitization"]["redacted_strings"] = redacted
        if rc != 0:
            print("LEAK CHECK FAILED after sanitize + redaction — nothing written. Offending keys:", file=sys.stderr)
            for o in offending or [{"path": "(unmapped)", "rule": "?", "match": "see upstream.py check output"}]:
                print(f"  {o['path']}  [{o['rule']}]", file=sys.stderr)
            return 2
        profile["sanitization"]["check"] = "pass"
        staged = tmp / "out"
        staged.mkdir()
        (staged / "profile.json").write_text(json.dumps(profile, indent=2, sort_keys=False) + "\n")
        (staged / "profile.md").write_text(render_md(profile))
        rc2, hits = run_check(upstream, args.config, str(ws), [staged])
        if rc2 != 0:
            print("LEAK CHECK FAILED on rendered artifacts — nothing written:", file=sys.stderr)
            for h in hits:
                print("  " + h.split(": ", 1)[-1], file=sys.stderr)
            return 2
        summary = (f"profile: {profile['workspace']['repos']} repo(s), "
                   f"{len(list(walk_strings(profile)))} string leaves, "
                   f"redactions {sum(profile['sanitization']['redactions'].values())}, "
                   f"redacted strings {redacted}, check pass")
        if args.dry_run:
            print(summary + " (dry-run, nothing written)")
            return 0
        out = Path(args.out)
        out.mkdir(parents=True, exist_ok=True)
        for name in ("profile.json", "profile.md"):
            shutil.copyfile(staged / name, out / name)
        print(summary + f" -> {out}")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def build_parser():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workspace", required=True, help="the workspace .claude directory (or its parent)")
    ap.add_argument("--repos", nargs="*", help="product repo roots (default: every <workspace-root>/*/ with a .claude/)")
    ap.add_argument("--config", required=True, help="upstream.json with the denylist")
    ap.add_argument("--out", help="output directory for profile.json + profile.md (required unless --dry-run)")
    ap.add_argument("--ci-runs", help="gh run list --json … output")
    ap.add_argument("--public-core", help="public repo core/ dir (or .upstream-base/) for drift counts")
    ap.add_argument("--dry-run", action="store_true", help="collect, sanitize, check; write nothing")
    ap.add_argument("--max-redaction-rounds", type=int, default=1)
    return ap


def main():
    args = build_parser().parse_args()
    if not args.out and not args.dry_run:
        sys.exit("error: --out is required unless --dry-run")
    if not Path(args.workspace).is_dir():
        sys.exit(f"error: --workspace is not a directory: {args.workspace}")
    sys.exit(harvest(args))


if __name__ == "__main__":
    main()
