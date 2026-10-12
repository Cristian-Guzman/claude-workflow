#!/usr/bin/env python3
"""
release.py — maintainer tool for the claude-workflow repo. NOT installed into projects.

  check                 Exit 1 if any shipped command's frontmatter version differs from
                        core/docs/workflow-version.md, if core/docs/inventory.yaml and the
                        shipped files disagree (both directions, per role), or if a shipped
                        text still carries an unfilled {PLACEHOLDER}.
  bump minor|patch      Compute the next version, propagate it into every command's
      [--theme "..."]   frontmatter (core/ and roles/*/), bump version:/last-updated: in
      [--apply]         workflow-version.md, and prepend a changelog scaffold whose bullets
                        are drafted from `git log <last release>..HEAD`. Prints a diff;
                        writes only with --apply.

Deterministic, stdlib only. Run from the repo root. Replaces the prose "release-manager
mode" that lived in bootstrap.md and the hash ledger (drift per install is answered by
scripts/upstream.py drift against the install baseline, not by a central ledger).
"""
import argparse
import datetime as dt
import difflib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent if (Path(__file__).resolve().parent.name == "scripts") else Path.cwd()
VERSION_DOC = "core/docs/workflow-version.md"
INVENTORY = "core/docs/inventory.yaml"
FM_VERSION = re.compile(r"^version:\s*(\S+)\s*$", re.M)
# Install-time substitutions that must never survive in a shipped file. Runtime template
# variables the commands resolve themselves ({REPO_ROOT}, {TICKET_ID}, ...) are NOT placeholders.
INSTALL_PLACEHOLDERS = ("{TARGET_VERSION}", "{PLACEMENT_DIR}", "{TICKET_CLI}", "{TICKET_ID_PATTERN}",
                        "{CI_COMMAND}", "{TEST_COMMAND}", "{LINT_COMMAND}", "{BUILD_COMMAND}", "{PR_HOST}")
PLACEHOLDER = re.compile("|".join(re.escape(x) for x in INSTALL_PLACEHOLDERS))
ROW = re.compile(r"^\s*-\s*\{(.*)\}\s*$")


def repo_root(arg):
    r = Path(arg).resolve()
    if not (r / VERSION_DOC).exists():
        sys.exit(f"error: {r} is not the claude-workflow repo root (no {VERSION_DOC})")
    return r


def command_files(root):
    """(role, path) for every shipped command. core/ is role 'core'; roles/<r>/commands is role r."""
    out = []
    for p in sorted((root / "core" / "commands").glob("*.md")):
        if p.name != "README.md":
            out.append(("core", p))
    for rd in sorted((root / "roles").glob("*/commands")) if (root / "roles").is_dir() else []:
        for p in sorted(rd.glob("*.md")):
            if p.name != "README.md":
                out.append((rd.parent.name, p))
    return out


def current_version(root):
    m = FM_VERSION.search((root / VERSION_DOC).read_text())
    if not m:
        sys.exit(f"error: no version: line in {VERSION_DOC}")
    return m.group(1)


def parse_inventory(root):
    """Rows are one-line flow mappings: - {name: x, role: y, priority: z, since: v, gate: "..."}"""
    p = root / INVENTORY
    if not p.exists():
        return None
    section, rows = None, {"commands": [], "agents": []}
    for line in p.read_text().splitlines():
        if re.match(r"^(commands|agents|structural):\s*$", line):
            section = line.split(":")[0]
            continue
        m = ROW.match(line)
        if m and section in rows:
            d = {}
            for kv in re.findall(r'(\w+):\s*("[^"]*"|\'[^\']*\'|[^,}]+)', m.group(1)):
                d[kv[0]] = kv[1].strip().strip('"').strip("'")
            rows[section].append(d)
    return rows


# ---------------------------------------------------------------- check
def cmd_check(args):
    root = repo_root(args.root)
    ver = current_version(root)
    problems = []
    files = command_files(root)
    for role, p in files:
        m = FM_VERSION.search(p.read_text()[:600])
        got = m.group(1) if m else "(none)"
        if got != ver:
            problems.append(f"version  {p.relative_to(root)}: {got} != {ver}")
        for i, line in enumerate(p.read_text().splitlines(), 1):
            if PLACEHOLDER.search(line) and p.name != "bootstrap.md":
                problems.append(f"placeholder {p.relative_to(root)}:{i}: {PLACEHOLDER.search(line).group(0)}")
    inv = parse_inventory(root)
    if inv is None:
        print(f"note: no {INVENTORY} — inventory check skipped")
    else:
        shipped = {(role, p.stem) for role, p in files}
        listed = {(r.get("role", "core"), r["name"]) for r in inv["commands"] if "name" in r}
        for role, name in sorted(listed - shipped):
            problems.append(f"inventory row without file: {name} (role {role})")
        for role, name in sorted(shipped - listed):
            problems.append(f"shipped file without inventory row: {name} (role {role})")
        agents_dir = root / "core" / "agents"
        shipped_agents = {p.stem for p in agents_dir.glob("*.md") if p.name != "README.md"}
        listed_agents = {r["name"] for r in inv["agents"] if "name" in r}
        for n in sorted(listed_agents - shipped_agents):
            problems.append(f"inventory agent without file: {n}")
        for n in sorted(shipped_agents - listed_agents):
            problems.append(f"shipped agent without inventory row: {n}")
    print(f"workflow version {ver} · {len(files)} commands checked")
    if problems:
        for pr in problems:
            print("  " + pr)
        print(f"\nCHECK FAILED — {len(problems)} problem(s)")
        return 1
    print("check clean")
    return 0


# ---------------------------------------------------------------- bump
def next_version(ver, kind):
    x, y, z = (int(n) for n in ver.split("."))
    return f"{x}.{y + 1}.0" if kind == "minor" else f"{x}.{y}.{z + 1}"


def last_release_ref(root, ver):
    for cand in (f"v{ver}", ver):
        r = subprocess.run(["git", "-C", str(root), "rev-parse", "-q", "--verify", cand], capture_output=True, text=True)
        if r.returncode == 0:
            return cand
    # no tag: the commit that last touched the version line
    r = subprocess.run(["git", "-C", str(root), "log", "-1", "--format=%H", "-S", f"version: {ver}", "--", VERSION_DOC],
                       capture_output=True, text=True)
    return r.stdout.strip() or None


def draft_bullets(root, since):
    rng = f"{since}..HEAD" if since else "HEAD"
    r = subprocess.run(["git", "-C", str(root), "log", "--no-merges", "--format=%s", rng], capture_output=True, text=True)
    subjects = [s for s in r.stdout.splitlines() if s.strip()]
    if not subjects:
        return ["- (no commits since the last release — write the bullets by hand)"]
    return [f"- {s}" for s in subjects]


def cmd_bump(args):
    root = repo_root(args.root)
    ver = current_version(root)
    new = next_version(ver, args.kind)
    today = dt.date.today().isoformat()
    changes = {}
    for role, p in command_files(root):
        text = p.read_text()
        head, sep, tail = text.partition("\n---\n") if text.startswith("---") else ("", "", text)
        if not sep:
            print(f"  skip {p.relative_to(root)} (no frontmatter)")
            continue
        new_head = FM_VERSION.sub(f"version: {new}", head, count=1)
        if new_head != head:
            changes[p] = new_head + sep + tail
    doc = root / VERSION_DOC
    text = doc.read_text()
    text2 = FM_VERSION.sub(f"version: {new}", text, count=1)
    text2 = re.sub(r"^last-updated:.*$", f"last-updated: {today}", text2, count=1, flags=re.M)
    theme = args.theme or "<one line: what this release is about>"
    bullets = "\n".join(draft_bullets(root, last_release_ref(root, ver)))
    entry = f"### {new} — {today}\n**Theme:** {theme}\n\n{bullets}\n\n"
    text2 = text2.replace("## Changelog\n\n", "## Changelog\n\n" + entry, 1)
    if text2 == text:
        sys.exit("error: could not find '## Changelog' / version: lines in workflow-version.md")
    changes[doc] = text2
    print(f"{ver} -> {new} ({args.kind}) · {len(changes) - 1} command frontmatters + {VERSION_DOC}")
    for p, content in changes.items():
        old = p.read_text()
        diff = difflib.unified_diff(old.splitlines(keepends=True), content.splitlines(keepends=True),
                                    fromfile=f"a/{p.relative_to(root)}", tofile=f"b/{p.relative_to(root)}")
        sys.stdout.writelines(list(diff)[:40] if p != doc else diff)
    if not args.apply:
        print("\n(dry run — re-run with --apply to write; suggested tag after commit: v" + new + ")")
        return 0
    for p, content in changes.items():
        p.write_text(content)
    print(f"\napplied. Next: edit the changelog bullets, commit, then `git tag v{new}`.")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".", help="repo root (default: CWD)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check"); c.set_defaults(fn=cmd_check)
    b = sub.add_parser("bump"); b.add_argument("kind", choices=["minor", "patch"])
    b.add_argument("--theme"); b.add_argument("--apply", action="store_true"); b.set_defaults(fn=cmd_bump)
    args = ap.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
