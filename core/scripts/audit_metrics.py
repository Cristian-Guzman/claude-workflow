#!/usr/bin/env python3
"""
Deterministic .claude self-learning metrics — Sigrid-style snapshot.

Outputs JSON to .claude/metrics/YYYY-MM-DD[-suffix].json so trend can be
diffed across snapshots.

Usage:
    python3 .claude/scripts/audit_metrics.py             # writes <DATE>.json
    python3 .claude/scripts/audit_metrics.py --suffix post   # writes <DATE>-post.json
    python3 .claude/scripts/audit_metrics.py --diff <fileA> <fileB>
"""
import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

WORKSPACE = Path(os.environ.get("WORKSPACE", os.path.expanduser("~/workspace")))
MEMORY_DIR = Path(os.environ.get(
    "MEMORY_DIR",
    os.path.expanduser("~/.claude/memory"),
))
OUT_DIR = WORKSPACE / ".claude" / "metrics"

# Restrict rule-violation scans to the user's OWN commits. Without this, `git log
# --all` sweeps every branch including teammates' and historical commits, turning a
# "personal rule-compliance" signal into noise (coauthor counts of 100+).
AUTHOR = os.environ.get("AUDIT_AUTHOR", "you@your-org.com")

# Minimum bytes for a codebase-patterns.md to count as a real, scannable file.
# Below this it's a stub/placeholder and would inject a false 0.0 specificity ratio.
MIN_PATTERNS_BYTES = 1500


def discover_repos():
    """Dynamically find repos with a substantive codebase-patterns.md.

    Replaces a hardcoded list that went stale (missed active repos like mail-service/
    billing-service and kept near-empty ones that reported a permanent 0.0 ratio).
    Mirrors the source ticket_cycle_time already trusts (the state index repos).
    """
    repos = []
    for f in sorted(WORKSPACE.glob("*/.claude/codebase-patterns.md")):
        try:
            if f.stat().st_size >= MIN_PATTERNS_BYTES:
                repos.append(f.parent.parent.name)
        except OSError:
            continue
    # A fresh workspace with no specialized repos yet produces a valid snapshot
    # with empty per-repo metrics — no hardcoded repo-name fallback.
    return repos


REPOS = discover_repos()

SPECIFIC_MARKERS = re.compile(
    r"\.(ts|tsx|js|jsx|go|md|sh|json|yaml|yml|py)\b"
    r"|#\d+\b"
    r"|PROJ-\d+"
    r"|\b[0-9a-f]{8,40}\b"
    r"|PR\s*#?\d+"
    r"|`[a-zA-Z_][\w]*\("
)


def pattern_specificity():
    results = []
    for repo in REPOS:
        f = WORKSPACE / repo / ".claude" / "codebase-patterns.md"
        entry = {"repo": repo, "total": 0, "specific": 0, "ratio": 0.0, "lines": 0}
        if f.exists():
            text = f.read_text(encoding="utf-8", errors="replace")
            sections = re.split(r"^## ", text, flags=re.MULTILINE)[1:]
            entry["total"] = len(sections)
            entry["specific"] = sum(1 for s in sections if SPECIFIC_MARKERS.search(s))
            entry["lines"] = text.count("\n")
            entry["ratio"] = round(entry["specific"] / entry["total"], 3) if entry["total"] else 0.0
        results.append(entry)
    return results


def memory_integrity():
    if not MEMORY_DIR.exists():
        return {"error": "memory dir missing"}
    files = sorted(f.name for f in MEMORY_DIR.glob("*.md") if f.name != "MEMORY.md")
    index_path = MEMORY_DIR / "MEMORY.md"
    index = index_path.read_text(encoding="utf-8", errors="replace") if index_path.exists() else ""
    referenced = set(re.findall(r"\(([\w_-]+\.md)\)", index))
    orphans = sorted(f for f in files if f not in referenced)
    broken = sorted(r for r in referenced if r not in files)

    bad_frontmatter = []
    for fname in files:
        head = (MEMORY_DIR / fname).read_text(encoding="utf-8", errors="replace")[:600]
        # `type:` may be flat (older files) or nested under `metadata:` (current
        # schema, indented) — accept both, else valid nested files false-flag.
        if not (
            re.search(r"^name:", head, re.M)
            and re.search(r"^description:", head, re.M)
            and re.search(r"^\s*type:", head, re.M)
        ):
            bad_frontmatter.append(fname)

    cutoff = datetime.now() - timedelta(days=30)
    stale_project = []
    for f in MEMORY_DIR.glob("project_*.md"):
        mtime = datetime.fromtimestamp(f.stat().st_mtime)
        if mtime < cutoff:
            stale_project.append({
                "file": f.name,
                "age_days": (datetime.now() - mtime).days,
            })
    stale_project.sort(key=lambda x: -x["age_days"])

    return {
        "total_files": len(files),
        "orphan_count": len(orphans),
        "orphans": orphans,
        "broken_pointer_count": len(broken),
        "broken_pointers": broken,
        "bad_frontmatter_count": len(bad_frontmatter),
        "bad_frontmatter": bad_frontmatter,
        "stale_project_memories_count": len(stale_project),
        "stale_project_memories": stale_project,
    }


def _git(repo_path, args, timeout=15):
    # Scrub GIT_* env vars: when this script runs from a git hook (pre-push
    # claude-audit-hook), git exports GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE,
    # and GIT_DIR OVERRIDES `-C` — every "per-repo" call silently reads the
    # repo being pushed. That corrupted the 2026-06-11 snapshot (identical
    # total_commits_30d=55 for all 10 repos). A clean env restores -C.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        r = subprocess.run(
            ["git", "-C", str(repo_path)] + args,
            capture_output=True, text=True, timeout=timeout, env=env,
        )
        return r.stdout
    except Exception:
        return ""


def rule_violations():
    since = (datetime.now() - timedelta(days=30)).strftime("%Y-%m-%d")
    coauthor_total = 0
    fix_lint_total = 0
    per_repo = {}
    for repo in REPOS:
        repo_path = WORKSPACE / repo
        if not (repo_path / ".git").exists():
            continue
        co_out = _git(repo_path, [
            "log", "--all", f"--since={since}", f"--author={AUTHOR}",
            "--pretty=format:%H",
            "--grep=Co-Authored-By",
            "--grep=Generated with Claude",
        ])
        co = len([x for x in co_out.split("\n") if x])

        fl_out = _git(repo_path, [
            "log", "--all", f"--since={since}", f"--author={AUTHOR}",
            "--pretty=format:%s",
            "-i",
            "--grep=fix lint",
            "--grep=fix prettier",
            "--grep=fix ci",
            "--grep=fix format",
            "--grep=address review",
        ])
        fl = len([x for x in fl_out.split("\n") if x])

        per_repo[repo] = {"coauthor": co, "fix_lint_followups": fl}
        coauthor_total += co
        fix_lint_total += fl

    return {
        "window_days": 30,
        "since": since,
        "totals": {
            "coauthor": coauthor_total,
            "fix_lint_followups": fix_lint_total,
        },
        "per_repo": per_repo,
    }


def learn_churn():
    sizes = {}
    for repo in REPOS:
        f = WORKSPACE / repo / ".claude" / "codebase-patterns.md"
        if not f.exists():
            sizes[repo] = None
            continue
        text = f.read_text(encoding="utf-8", errors="replace")
        sizes[repo] = {
            "lines": text.count("\n"),
            "bytes": f.stat().st_size,
            "h2_sections": len(re.findall(r"^## ", text, re.M)),
        }
    return sizes


def ci_first_pass_proxy():
    since = (datetime.now() - timedelta(days=30)).strftime("%Y-%m-%d")
    rework_re = re.compile(
        r"fix\s+(lint|prettier|ci|format|build|tests?)|address review|"
        r"fix typo|fix prettier|format check|review fix",
        re.I,
    )
    per_repo = {}
    for repo in REPOS:
        repo_path = WORKSPACE / repo
        if not (repo_path / ".git").exists():
            continue
        out = _git(repo_path, [
            "log", "--all", f"--since={since}", "--pretty=format:%s",
        ])
        commits = [x for x in out.split("\n") if x]
        total = len(commits)
        rework = sum(1 for c in commits if rework_re.search(c))
        per_repo[repo] = {
            "total_commits_30d": total,
            "rework_commits": rework,
            "rework_pct": round(rework / total * 100, 1) if total else 0.0,
        }
    return per_repo


def ticket_cycle_time():
    """Mean/median hours from /ticket state-file creation to PR merge.

    Joins state/index.json ticket entries (kind=ticket, branch != placeholder)
    with `gh pr list --state merged --limit 200 --json mergedAt,headRefName`
    per repo, by head branch name. Window = last 30 days of merges.
    """
    index_path = WORKSPACE / ".claude" / "state" / "index.json"
    if not index_path.exists():
        return {"error": "state/index.json missing"}
    try:
        idx = json.loads(index_path.read_text(encoding="utf-8", errors="replace"))
    except Exception as e:
        return {"error": f"index.json parse failed: {e}"}

    tickets_by_branch = {}
    for entry in idx.get("entries", []):
        if entry.get("kind") != "ticket":
            continue
        repo = entry.get("repo")
        branch = entry.get("branch")
        created = entry.get("created")
        if not (repo and branch and created):
            continue
        if branch in ("(to be determined)", "TBD", "main", "develop"):
            continue
        tickets_by_branch.setdefault(repo, {})[branch] = created

    cutoff = datetime.now(timezone.utc) - timedelta(days=30)
    per_repo = {}
    all_hours = []
    for repo, branches in tickets_by_branch.items():
        repo_path = WORKSPACE / repo
        if not (repo_path / ".git").exists():
            continue
        try:
            r = subprocess.run(
                ["gh", "pr", "list", "--state", "merged", "--limit", "200",
                 "--json", "mergedAt,headRefName"],
                cwd=str(repo_path),
                capture_output=True, text=True, timeout=20,
            )
            prs = json.loads(r.stdout) if r.stdout else []
        except Exception:
            prs = []

        merged_by_branch = {
            p["headRefName"]: p["mergedAt"]
            for p in prs if p.get("mergedAt") and p.get("headRefName")
        }

        hours_list = []
        for branch, created_iso in branches.items():
            merged_iso = merged_by_branch.get(branch)
            if not merged_iso:
                continue
            try:
                created_dt = datetime.fromisoformat(created_iso.replace("Z", "+00:00"))
                merged_dt = datetime.fromisoformat(merged_iso.replace("Z", "+00:00"))
            except Exception:
                continue
            # State-file `created:` sometimes lacks a timezone suffix — treat naive
            # as UTC (gh's mergedAt is always tz-aware; naive-vs-aware math throws).
            if created_dt.tzinfo is None:
                created_dt = created_dt.replace(tzinfo=timezone.utc)
            if merged_dt.tzinfo is None:
                merged_dt = merged_dt.replace(tzinfo=timezone.utc)
            if merged_dt < cutoff:
                continue
            hours = (merged_dt - created_dt).total_seconds() / 3600.0
            if hours < 0:
                continue
            hours_list.append(hours)

        if hours_list:
            hours_list.sort()
            n = len(hours_list)
            mean_h = sum(hours_list) / n
            median_h = hours_list[n // 2] if n % 2 else (hours_list[n // 2 - 1] + hours_list[n // 2]) / 2
            per_repo[repo] = {
                "ticket_pr_pairs_30d": n,
                "mean_hours_to_merge": round(mean_h, 1),
                "median_hours_to_merge": round(median_h, 1),
                "min_hours": round(min(hours_list), 1),
                "max_hours": round(max(hours_list), 1),
            }
            all_hours.extend(hours_list)
        else:
            per_repo[repo] = {"ticket_pr_pairs_30d": 0}

    overall = {}
    if all_hours:
        all_hours.sort()
        n = len(all_hours)
        median = all_hours[n // 2] if n % 2 else (all_hours[n // 2 - 1] + all_hours[n // 2]) / 2
        overall = {
            "ticket_pr_pairs_30d": n,
            "mean_hours_to_merge": round(sum(all_hours) / n, 1),
            "median_hours_to_merge": round(median, 1),
        }

    return {
        "window_days": 30,
        "per_repo": per_repo,
        "overall": overall,
    }


def stale_and_integrity():
    claude_root = WORKSPACE / ".claude"
    cutoff = datetime.now() - timedelta(days=60)
    stale = []
    if claude_root.exists():
        for f in claude_root.rglob("*"):
            if not f.is_file():
                continue
            # skip hidden subdirs (e.g., .obsidian, .DS_Store)
            rel_parts = f.relative_to(claude_root).parts
            if any(p.startswith(".") for p in rel_parts):
                continue
            try:
                mtime = datetime.fromtimestamp(f.stat().st_mtime)
                if mtime < cutoff:
                    stale.append({
                        "file": str(f.relative_to(WORKSPACE)),
                        "age_days": (datetime.now() - mtime).days,
                    })
            except Exception:
                pass
    stale.sort(key=lambda x: -x["age_days"])

    empty_tmp = []
    for repo in REPOS:
        tdir = WORKSPACE / repo / ".claude" / "tickets"
        if tdir.exists():
            for f in tdir.glob("*.md.tmp"):
                if f.stat().st_size == 0:
                    empty_tmp.append(str(f.relative_to(WORKSPACE)))

    do_md = claude_root / "commands" / "do.md"
    commands_dir = claude_root / "commands"
    routing = None
    if do_md.exists() and commands_dir.exists():
        do_text = do_md.read_text(encoding="utf-8", errors="replace")
        # README is the command catalog, not a command. `do` is the file we're scoring against.
        non_command_stems = {"do", "README", "readme"}
        all_commands = sorted(
            f.stem for f in commands_dir.glob("*.md") if f.stem not in non_command_stems
        )
        referenced = [c for c in all_commands if re.search(rf"/{c}\b", do_text)]
        missing = sorted(set(all_commands) - set(referenced))
        routing = {
            "total_commands": len(all_commands),
            "referenced_in_do": len(referenced),
            "missing": missing,
            "missing_count": len(missing),
            "coverage_pct": round(len(referenced) / len(all_commands) * 100, 1) if all_commands else 0.0,
        }

    agents_dir = claude_root / "agents"
    agent_drift = None
    if agents_dir.exists():
        actual_agents = sorted(
            f.stem for f in agents_dir.glob("*.md") if f.stem != "README"
        )
        readme_path = agents_dir / "README.md"
        ghost = []
        if readme_path.exists():
            readme = readme_path.read_text(encoding="utf-8", errors="replace")
            mentioned = set(re.findall(r"`([a-z][a-z0-9-]+)`", readme))
            for m in mentioned:
                if "-" in m and m not in actual_agents and len(m) < 40:
                    ghost.append(m)
        agent_drift = {
            "actual_agents": actual_agents,
            "ghost_references": sorted(set(ghost)),
            "ghost_count": len(set(ghost)),
        }

    return {
        "stale_files_60d_count": len(stale),
        "stale_files_60d_top": stale[:15],
        "empty_tmp_ticket_files_count": len(empty_tmp),
        "empty_tmp_ticket_files": empty_tmp,
        "do_routing": routing,
        "agent_drift": agent_drift,
    }


def headline(snapshot):
    m = snapshot["metrics"]
    print(f"=== Headline metrics — {snapshot['date']} ===")
    for s in m["pattern_specificity"]:
        print(
            f"  spec[{s['repo']:<28}] "
            f"{s['specific']:>3}/{s['total']:<3} = {s['ratio']:.2f}  "
            f"({s['lines']} lines)"
        )
    mi = m["memory_integrity"]
    print(
        f"  memory: {mi['total_files']} files | "
        f"orphans={mi['orphan_count']} broken={mi['broken_pointer_count']} "
        f"badFM={mi['bad_frontmatter_count']} staleProj={mi['stale_project_memories_count']}"
    )
    rv = m["rule_violations_30d"]
    print(
        f"  violations(30d): coauthor={rv['totals']['coauthor']} "
        f"fix-lint={rv['totals']['fix_lint_followups']}"
    )
    ct = m.get("ticket_cycle_time", {})
    if ct.get("overall", {}).get("ticket_pr_pairs_30d"):
        o = ct["overall"]
        print(
            f"  ticket cycle (30d): n={o['ticket_pr_pairs_30d']} "
            f"mean={o['mean_hours_to_merge']}h median={o['median_hours_to_merge']}h"
        )
        for repo, st in ct.get("per_repo", {}).items():
            n = st.get("ticket_pr_pairs_30d", 0)
            if n:
                print(
                    f"    cycle[{repo:<28}] n={n:<2} "
                    f"mean={st['mean_hours_to_merge']}h median={st['median_hours_to_merge']}h"
                )
    si = m["stale_and_integrity"]
    print(f"  stale .claude files >60d: {si['stale_files_60d_count']}")
    print(f"  empty .tmp ticket files: {si['empty_tmp_ticket_files_count']}")
    if si["do_routing"]:
        print(
            f"  /do routing coverage: {si['do_routing']['coverage_pct']}% "
            f"({si['do_routing']['referenced_in_do']}/{si['do_routing']['total_commands']})"
        )
    if si["agent_drift"]:
        print(
            f"  agent ghost references: {si['agent_drift']['ghost_count']} "
            f"(actual={len(si['agent_drift']['actual_agents'])})"
        )


def diff_snapshots(path_a, path_b):
    a = json.loads(Path(path_a).read_text())
    b = json.loads(Path(path_b).read_text())
    print(f"=== Diff: {a['date']} -> {b['date']} ===")

    # Pattern specificity
    a_spec = {x["repo"]: x for x in a["metrics"]["pattern_specificity"]}
    b_spec = {x["repo"]: x for x in b["metrics"]["pattern_specificity"]}
    for repo in sorted(set(a_spec) | set(b_spec)):
        ra = a_spec.get(repo, {}).get("ratio", 0)
        rb = b_spec.get(repo, {}).get("ratio", 0)
        la = a_spec.get(repo, {}).get("lines", 0)
        lb = b_spec.get(repo, {}).get("lines", 0)
        delta_r = rb - ra
        delta_l = lb - la
        arrow = "→" if abs(delta_r) < 0.005 else ("↑" if delta_r > 0 else "↓")
        print(
            f"  spec[{repo:<28}] {ra:.2f} {arrow} {rb:.2f}  "
            f"(Δratio {delta_r:+.2f}, Δlines {delta_l:+})"
        )

    # Memory
    am = a["metrics"]["memory_integrity"]
    bm = b["metrics"]["memory_integrity"]
    for k in ("orphan_count", "broken_pointer_count", "bad_frontmatter_count",
              "stale_project_memories_count"):
        print(f"  memory.{k}: {am.get(k, 0)} -> {bm.get(k, 0)}")

    # Violations
    av = a["metrics"]["rule_violations_30d"]["totals"]
    bv = b["metrics"]["rule_violations_30d"]["totals"]
    for k in ("coauthor", "fix_lint_followups"):
        print(f"  violations.{k}: {av.get(k, 0)} -> {bv.get(k, 0)}")

    # Ticket cycle time
    act = a["metrics"].get("ticket_cycle_time", {}).get("overall", {})
    bct = b["metrics"].get("ticket_cycle_time", {}).get("overall", {})
    if act.get("ticket_pr_pairs_30d") or bct.get("ticket_pr_pairs_30d"):
        am_h = act.get("mean_hours_to_merge", 0)
        bm_h = bct.get("mean_hours_to_merge", 0)
        delta = bm_h - am_h
        arrow = "→" if abs(delta) < 0.5 else ("↓" if delta < 0 else "↑")
        print(
            f"  cycle.mean_hours: {am_h} {arrow} {bm_h}  "
            f"(Δ {delta:+.1f}h, n {act.get('ticket_pr_pairs_30d', 0)}→{bct.get('ticket_pr_pairs_30d', 0)})"
        )

    # Stale + integrity
    asi = a["metrics"]["stale_and_integrity"]
    bsi = b["metrics"]["stale_and_integrity"]
    print(
        f"  stale_files_60d: {asi['stale_files_60d_count']} -> {bsi['stale_files_60d_count']}"
    )
    print(
        f"  empty_tmp_files: {asi['empty_tmp_ticket_files_count']} -> {bsi['empty_tmp_ticket_files_count']}"
    )
    if asi.get("do_routing") and bsi.get("do_routing"):
        print(
            f"  /do coverage: {asi['do_routing']['coverage_pct']}% -> {bsi['do_routing']['coverage_pct']}%"
        )
    if asi.get("agent_drift") and bsi.get("agent_drift"):
        print(
            f"  agent ghosts: {asi['agent_drift']['ghost_count']} -> {bsi['agent_drift']['ghost_count']}"
        )


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--suffix", default="", help="Suffix appended to the date in the filename (e.g., 'post')")
    p.add_argument("--diff", nargs=2, metavar=("A", "B"))
    args = p.parse_args()

    if args.diff:
        diff_snapshots(args.diff[0], args.diff[1])
        return

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    date = datetime.now().strftime("%Y-%m-%d")
    snapshot = {
        "date": date,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "schema_version": 1,
        "workspace": str(WORKSPACE),
        "metrics": {
            "pattern_specificity": pattern_specificity(),
            "memory_integrity": memory_integrity(),
            "rule_violations_30d": rule_violations(),
            "learn_churn": learn_churn(),
            "ci_first_pass_proxy": ci_first_pass_proxy(),
            "ticket_cycle_time": ticket_cycle_time(),
            "stale_and_integrity": stale_and_integrity(),
        },
    }
    fname = f"{date}{('-' + args.suffix) if args.suffix else ''}.json"
    out_file = OUT_DIR / fname
    out_file.write_text(json.dumps(snapshot, indent=2))
    print(f"Wrote {out_file}")
    print()
    headline(snapshot)


if __name__ == "__main__":
    main()
