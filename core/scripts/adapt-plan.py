#!/usr/bin/env python3
"""
adapt-plan.py — the mechanical half of /bootstrap's decision step.

  adapt-plan.py --root .claude --vector vector.json [--roles dev,sdet] [--json]

Reads the capability vector (from capability-probe.sh, with any "?" already answered),
the inventory (.claude/inventory.yaml), the installed roles (from --roles, else the
vector's roles[], else inferred from which role directories' commands are present), and
the state of each command/agent file, and emits one decision per row:

  KEEP · KEEP(in-use) · KEEP(core) · PRUNE · UN-ARCHIVE · MISSING · IGNORE · ORPHAN
  (ORPHAN = a file in commands/ or agents/ with no inventory row. install.sh already archives a
   retired file when the previous baseline proves it was upstream's and it is unmodified, so an
   orphan is one of two things, and the reason says which: a LOCALLY EDITED retired file the
   installer kept (its copy is in .upstream-prior/<date>/), or a leftover from a pre-baseline
   (< 0.7.0) install. Reported, never moved — the owner archives by hand after a look.)

Rules (fail-safe):
  - gate grammar: always | <cap> == <v> | <cap> != <v> | <cap> >= <n> | A AND B | A OR B | ( ... )
    ui_surfaces is a comma list: "!= none" means non-empty, "== web" means contains web.
  - a gate that does not parse => KEEP + parse_error (never prune on a broken expression)
  - priority core + gate always => never pruned
  - in-use gate: any state/index.json entry (or artifact dir) naming the command => KEEP(in-use) with a
    "gate false but used — fix the probe/profile" reason. Usage beats the probe; file age is NOT evidence
    (on a fresh install every file is new, and the first run is exactly when pruning matters).
  - "?" anywhere in the vector => exit 3 before deciding (the command must ask first)
The script never moves a file. /bootstrap shows the table, gets approval, then moves.
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROW = re.compile(r"^\s*-\s*\{(.*)\}\s*$")
ARTIFACT_DIRS = {"qa": "qa", "screenshot": "screenshots", "demo-summary": "demos", "project-debug": "debug",
                 "build": "builds", "refactor": "refactors", "upstream": "upstream"}


def parse_inventory(path):
    section, rows = None, {"commands": [], "agents": [], "structural": []}
    for line in Path(path).read_text().splitlines():
        if re.match(r"^(commands|agents|structural):\s*$", line):
            section = line.split(":")[0]
            continue
        m = ROW.match(line)
        if m and section in rows:
            d = {}
            for k, v in re.findall(r'(\w+):\s*("[^"]*"|\'[^\']*\'|[^,}]+)', m.group(1)):
                d[k] = v.strip().strip('"').strip("'")
            rows[section].append(d)
    return rows


# ---------------------------------------------------------------- gate evaluator
TOK = re.compile(r"\s*(\(|\)|AND|OR|==|!=|>=|<=|[A-Za-z_][\w.]*|[^\s()]+)")


class GateError(Exception):
    pass


def tokenize(expr):
    out, pos = [], 0
    while pos < len(expr):
        m = TOK.match(expr, pos)
        if not m or m.end() == pos:
            raise GateError(f"cannot tokenize at {expr[pos:]!r}")
        out.append(m.group(1))
        pos = m.end()
    return out


def evaluate(expr, vec):
    expr = expr.strip().strip('"').strip("'")
    if expr == "always":
        return True
    toks = tokenize(expr)
    i = 0

    def peek():
        return toks[i] if i < len(toks) else None

    def take():
        nonlocal i
        t = toks[i]
        i += 1
        return t

    def value(cap):
        if cap not in vec:
            raise GateError(f"unknown capability {cap!r}")
        return vec[cap]

    def cmp(cap, op, lit):
        v = value(cap)
        if cap == "ui_surfaces":
            items = [x for x in str(v).split(",") if x and x != "none"]
            if lit == "none":
                return (len(items) == 0) if op == "==" else (len(items) > 0)
            return (lit in items) if op == "==" else (lit not in items)
        if op in (">=", "<="):
            a, b = float(v), float(lit)
            return a >= b if op == ">=" else a <= b
        sv = str(v).lower()
        return (sv == lit.lower()) if op == "==" else (sv != lit.lower())

    def atom():
        t = take()
        if t == "(":
            r = expr_or()
            if take() != ")":
                raise GateError("missing )")
            return r
        if t == "always":
            return True
        op = take()
        if op not in ("==", "!=", ">=", "<="):
            raise GateError(f"expected operator after {t!r}, got {op!r}")
        return cmp(t, op, take())

    def expr_and():
        r = atom()
        while peek() == "AND":
            take()
            r = atom() and r
        return r

    def expr_or():
        r = expr_and()
        while peek() == "OR":
            take()
            r = expr_and() or r
        return r

    result = expr_or()
    if i != len(toks):
        raise GateError(f"trailing tokens {toks[i:]!r}")
    return result


# ---------------------------------------------------------------- decisions
def infer_roles(claude):
    """Pre-manifest install: a role is on if any of its commands is present (mirrors install.sh)."""
    roles = []
    inv = claude / "inventory.yaml"
    if not inv.exists():
        return roles
    present = {p.stem for p in (claude / "commands").glob("*.md")}
    for r in parse_inventory(inv)["commands"]:
        if r.get("role", "core") != "core" and r["name"] in present and r["role"] not in roles:
            roles.append(r["role"])
    return roles


def in_use(claude, name):
    """Usage evidence: a state-index entry naming the command, or a non-empty artifact dir it writes."""
    d = ARTIFACT_DIRS.get(name)
    if d and any((claude / d).glob("*")):
        return f".claude/{d}/ has artifacts"
    idx = claude / "state" / "index.json"
    if idx.exists():
        try:
            data = json.loads(idx.read_text())
        except json.JSONDecodeError:
            data = {}
        needle = f"/{name}"
        for e in data.get("entries", []):
            if e.get("kind") == name or needle in str(e.get("path", "")) or name in str(e.get("tags", "")):
                return "state/index.json has entries for it"
    return ""


def decide(row, kind, claude, vec, roles):
    name = row["name"]
    role = row.get("role", "core")
    live_dir = claude / ("commands" if kind == "commands" else "agents")
    arch_dir = claude / "_archived-commands" if kind == "commands" else claude / "_archived-agents"
    live, arch = live_dir / f"{name}.md", arch_dir / f"{name}.md"
    out = {"name": name, "kind": kind[:-1], "role": role, "priority": row.get("priority", ""), "gate": row.get("gate", "always")}
    if role != "core" and role not in roles:
        out.update(decision="IGNORE", reason=f"role {role} not installed")
        return out
    try:
        ok = evaluate(out["gate"], vec)
    except GateError as e:
        out.update(decision="KEEP" if live.exists() else "IGNORE", reason=f"parse_error: {e}")
        return out
    if live.exists():
        if ok:
            out.update(decision="KEEP", reason="gate true")
        elif row.get("priority") == "core" and out["gate"].strip('"') == "always":
            out.update(decision="KEEP(core)", reason="core + always is never pruned")
        else:
            used = in_use(claude, name)
            if used:
                out.update(decision="KEEP(in-use)", reason=f"gate false ({out['gate']}) but {used} — fix the profile/probe, not the command")
            else:
                out.update(decision="PRUNE", reason=f"gate false: {out['gate']}")
    elif arch.exists():
        out.update(decision="UN-ARCHIVE" if ok else "IGNORE", reason="gate true, file archived" if ok else "archived, gate false")
    else:
        out.update(decision="MISSING" if ok else "IGNORE",
                   reason=(f"gate true, not installed → install.sh <root> --role {role}" if ok else "not installed, gate false"))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".claude")
    ap.add_argument("--vector", required=True)
    ap.add_argument("--roles")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    claude = Path(args.root).resolve()
    vec = json.loads(Path(args.vector).read_text())
    unknown = [k for k, v in vec.items() if v == "?"]
    if unknown:
        print(f"vector has unresolved values: {', '.join(unknown)} — ask the user, then re-run", file=sys.stderr)
        sys.exit(3)
    inv_path = claude / "inventory.yaml"
    if not inv_path.exists():
        sys.exit(f"error: {inv_path} missing — install.sh 0.9.0+ ships it")
    inv = parse_inventory(inv_path)
    roles = [r for r in (args.roles.split(",") if args.roles else vec.get("roles") or []) if r] or infer_roles(claude)
    rows = [decide(r, "commands", claude, vec, roles) for r in inv["commands"] if "name" in r]
    rows += [decide(r, "agents", claude, vec, roles) for r in inv["agents"] if "name" in r]
    # orphans: shipped files no inventory row names. install.sh archives a retired file itself when
    # the previous baseline proves it was upstream's AND it is unmodified; whatever is left is either
    # a locally edited retired file it kept (captured under .upstream-prior/) or a pre-baseline leftover.
    listed = {(k, r["name"]) for k in ("commands", "agents") for r in inv[k] if "name" in r}
    for kind in ("commands", "agents"):
        for f in sorted((claude / kind).glob("*.md")):
            if f.name == "README.md" or (kind, f.stem) in listed:
                continue
            captures = sorted(claude.glob(f".upstream-prior/*/installed/{kind}/{f.name}")) + \
                       sorted(claude.glob(f".upstream-prior/*/{kind}/{f.name}"))
            archived = (claude / ("_archived-commands" if kind == "commands" else "_archived-agents") / f.name).exists()
            if captures:
                rel = captures[-1].relative_to(claude)
                reason = f"retired upstream but locally edited — install.sh kept it; your copy is at .claude/{rel}; review, then archive by hand"
            else:
                reason = "retired upstream; this install predates the baseline (< 0.7.0) so install.sh could not prove it was upstream's — archive by hand"
            if archived:
                reason += " (an archived copy already exists — compare before overwriting)"
            rows.append({"name": f.stem, "kind": kind[:-1], "role": "?", "priority": "", "gate": "",
                         "decision": "ORPHAN", "reason": reason})
    counts = {}
    for r in rows:
        counts[r["decision"]] = counts.get(r["decision"], 0) + 1
    result = {"roles": roles, "counts": counts, "rows": rows}
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"roles: {', '.join(roles) or '(none)'} · " + " · ".join(f"{k} {v}" for k, v in sorted(counts.items())))
        for r in rows:
            if r["decision"] != "IGNORE":
                print(f"  {r['decision']:15} {r['kind']:8} {r['name']:20} {r['role']:5} {r['reason']}")
    sys.exit(0)


if __name__ == "__main__":
    main()
