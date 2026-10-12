#!/usr/bin/env python3
"""
upstream.py — the mechanical half of /upstream.

Subcommands, all deterministic, stdlib only (macOS system python3 is enough):

  drift     Diff the installed core (.claude/commands, agents, scripts, root docs)
            against the baseline snapshot install.sh wrote to .claude/.upstream-base/.
            One unified diff per locally-modified core file — the strongest upstream
            candidates: edits a project made because the generic command was wrong for it.

  sanitize  Rewrite files in place (or --out DIR) with the redaction rules from
            .claude/upstream.json: ticket keys -> PROJ-n, emails, denied domains and
            URLs, workspace/home paths, repo aliases, every denylist term.

  check     Scan files for anything that must not leave the machine. Exit 1 and list
            file:line:match on any hit. Secrets patterns (cloud keys, tokens, private
            keys, JWTs) are ALWAYS on and cannot be disabled by config. --generic adds
            config-free heuristics (emails, foreign ticket keys, /Users|/home paths) for
            the intake side, which has no denylist.

  env       Classify this machine: company or personal. Signals: MDM enrollment, the
            global git email's domain against denied_domains, non-github.com hosts in
            `gh auth status`. Any company signal => bundle-only mode in /upstream.

  identity  Scoped git identity swap for the intake commit: `save` records the repo's
            current LOCAL user.name / user.email / commit.gpgsign / user.signingkey,
            `set` writes the personal identity and disables signing, `restore` puts the
            saved values back (unsetting what was unset) and deletes the backup. The
            global config is never touched.

  log       Append one line to .claude/upstream/HARVEST-LOG.md — the audit trail of what
            was harvested, with which denylist (hash), with what check result, to where.

Design rule: the model generalizes prose; this script decides what is a leak and what
identity a commit carries. It fails closed — an empty or placeholder denylist is an error.
"""
import argparse
import difflib
import hashlib
import json
import os
import platform
import re
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

CORE_MAP = {  # baseline path (as in core/) -> installed path (relative to .claude/)
    "commands": "commands",
    "agents": "agents",
    "scripts": "scripts",
    "docs": ".",  # core/docs/*.md land at .claude/*.md
    "learn-targets": "learn-targets",  # roles/<r>/learn-targets.yaml -> .claude/learn-targets/<r>.yaml
}

EMAIL_RX = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

GENERIC_PATTERNS = [
    ("email", EMAIL_RX),
    ("home-path", re.compile(r"(?:/Users/|/home/)[A-Za-z0-9._-]+")),
    ("ticket-key", re.compile(r"\b(?!PROJ-)[A-Z]{2,6}-\d{2,6}\b")),
]

# Always on. A hit here is a credential, never a false positive worth arguing about.
SECRET_PATTERNS = [
    ("aws-access-key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("github-token", re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b")),
    ("slack-token", re.compile(r"\bxox[abpors]-[A-Za-z0-9-]{10,}\b")),
    ("private-key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |PGP )?PRIVATE KEY")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")),
    ("openai-style-key", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b")),
    ("generic-assignment", re.compile(r"(?i)\b(?:api[_-]?key|secret|token|password|passwd)\b\s*[:=]\s*['\"]?[A-Za-z0-9/+_\-]{12,}")),
]
SECRET_NAMES = {n for n, _ in SECRET_PATTERNS}

IDENTITY_KEYS = ["user.name", "user.email", "commit.gpgsign", "user.signingkey"]


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(cmd, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, **kw)
    except FileNotFoundError:
        return subprocess.CompletedProcess(cmd, 127, "", f"{cmd[0]}: not found")


# ---------------------------------------------------------------- config
def is_placeholder(v):
    return isinstance(v, str) and v.startswith("<")


def load_config(path, require_denylist=True):
    p = Path(path)
    if not p.exists():
        sys.exit(f"error: config not found: {p}\n"
                 "       seed it: cp templates/workspace/upstream.template.json .claude/upstream.json")
    cfg = json.loads(p.read_text())
    denylist = [t for t in cfg.get("denylist", []) if t and not is_placeholder(t)]
    domains = [d for d in cfg.get("denied_domains", []) if d and d != "example.com" and not is_placeholder(d)]
    if require_denylist and not denylist and not domains:
        sys.exit("error: upstream.json has an empty denylist and no denied_domains — "
                 "fill in the company, product and people names before harvesting (fail-closed)")
    cfg["denylist"] = denylist
    cfg["denied_domains"] = domains
    cfg["ticket_prefixes"] = [x for x in cfg.get("ticket_prefixes", []) if x and x != "PROJ" and not is_placeholder(x)]
    cfg["repo_aliases"] = {k: v for k, v in cfg.get("repo_aliases", {}).items() if k and not is_placeholder(k)}
    pid = cfg.get("personal_identity") or {}
    cfg["personal_identity"] = {k: v for k, v in pid.items() if v and not is_placeholder(v)}
    return cfg


def resolve_roots(cfg, claude_dir):
    roots = []
    ws = cfg.get("workspace_root") or os.environ.get("WORKSPACE_ROOT") or str(Path(claude_dir).resolve().parent)
    roots.append((ws.rstrip("/"), "$WORKSPACE_ROOT"))
    roots.append((str(Path.home()), "$HOME"))
    return roots


# ---------------------------------------------------------------- rules
def build_rules(cfg, claude_dir):
    """Ordered (name, regex, replacement) — longest/most specific first within each class."""
    rules = []
    for src, alias in resolve_roots(cfg, claude_dir):
        rules.append(("path", re.compile(re.escape(src)), alias))
    for d in sorted(cfg["denied_domains"], key=len, reverse=True):
        rules.append(("url", re.compile(r"https?://[^\s)\]>\"']*" + re.escape(d) + r"[^\s)\]>\"']*"),
                      "https://example.com/[redacted]"))
        rules.append(("domain", re.compile(r"\b" + re.escape(d) + r"\b", re.I), "example.com"))
    rules.append(("email", EMAIL_RX, "user@example.com"))
    for pfx in sorted(cfg["ticket_prefixes"], key=len, reverse=True):
        rules.append(("ticket", re.compile(r"\b" + re.escape(pfx) + r"-(\d+)\b"), r"PROJ-\1"))
    if cfg.get("redact_all_ticket_keys", True):
        rules.append(("ticket-any", re.compile(r"\b(?!PROJ-)[A-Z]{2,6}-(\d{2,6})\b"), r"PROJ-\1"))
    for name, alias in sorted(cfg["repo_aliases"].items(), key=lambda kv: len(kv[0]), reverse=True):
        rules.append(("repo", re.compile(r"(?<![\w-])" + re.escape(name) + r"(?![\w-])", re.I), alias))
    for term in sorted(cfg["denylist"], key=len, reverse=True):
        rules.append(("denylist", re.compile(r"(?<!\w)" + re.escape(term) + r"(?!\w)", re.I), "[REDACTED]"))
    return rules


def apply_rules(text, rules):
    counts = {}
    for name, rx, rep in rules:
        text, n = rx.subn(rep, text)
        if n:
            counts[name] = counts.get(name, 0) + n
    return text, counts


# ---------------------------------------------------------------- drift
def file_sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def cmd_drift(args):
    claude = Path(args.root).resolve()
    base = claude / ".upstream-base"
    manifest_path = claude / ".upstream-manifest.json"
    if not base.is_dir():
        sys.exit(f"error: no baseline at {base} — re-run install.sh (0.7.0+) to record one; "
                 "drift detection is skipped on older installs")
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    out = Path(args.out) if args.out else None
    if out:
        out.mkdir(parents=True, exist_ok=True)
    results = []
    for top, dest in CORE_MAP.items():
        src_dir = base / top
        if not src_dir.is_dir():
            continue
        for bp in sorted(src_dir.rglob("*")):
            if not bp.is_file():
                continue
            rel = bp.relative_to(src_dir)
            ip = (claude / dest / rel).resolve()
            if not ip.exists():
                results.append({"file": f"{top}/{rel}", "status": "missing"})
                continue
            if file_sha(bp) == file_sha(ip):
                continue
            b_lines = bp.read_text(errors="replace").splitlines(keepends=True)
            i_lines = ip.read_text(errors="replace").splitlines(keepends=True)
            diff = list(difflib.unified_diff(b_lines, i_lines, fromfile=f"a/{top}/{rel}", tofile=f"b/{top}/{rel}"))
            changed = sum(1 for ln in diff[2:] if ln[:1] in "+-")
            entry = {"file": f"{top}/{rel}", "status": "modified", "changed_lines": changed}
            if out:
                dp = out / (str(rel).replace("/", "__") + ".diff")
                dp.write_text("".join(diff))
                entry["diff"] = str(dp)
            results.append(entry)
    summary = {
        "baseline_version": manifest.get("version", "unknown"),
        "baseline_commit": manifest.get("source_commit", "unknown"),
        "installed_at": manifest.get("installed_at", "unknown"),
        "files": results,
    }
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print(f"baseline {summary['baseline_version']} ({summary['baseline_commit']}) installed {summary['installed_at']}")
        if not results:
            print("no local edits to core files")
        for r in results:
            extra = f" ({r['changed_lines']} lines)" if r["status"] == "modified" else ""
            print(f"  {r['status']:8} {r['file']}{extra}")
    return 0


# ---------------------------------------------------------------- sanitize / check
def iter_files(paths):
    for p in paths:
        p = Path(p)
        if p.is_dir():
            for f in sorted(p.rglob("*")):
                if f.is_file() and not f.name.startswith("."):
                    yield f
        elif p.is_file():
            yield p


def cmd_sanitize(args):
    cfg = load_config(args.config)
    rules = build_rules(cfg, args.root)
    total = {}
    for f in iter_files(args.paths):
        text = f.read_text(errors="replace")
        new, counts = apply_rules(text, rules)
        for k, v in counts.items():
            total[k] = total.get(k, 0) + v
        dest = f
        if args.out:
            dest = Path(args.out) / f.name
            dest.parent.mkdir(parents=True, exist_ok=True)
        if new != text or args.out:
            dest.write_text(new)
        if counts:
            print(f"  {f}: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    print("sanitized: " + (", ".join(f"{k}={v}" for k, v in sorted(total.items())) or "nothing to redact"))
    return 0


def cmd_check(args):
    patterns = []
    if args.config:
        cfg = load_config(args.config)
        for src, _ in resolve_roots(cfg, args.root):
            patterns.append(("path", re.compile(re.escape(src))))
        for d in cfg["denied_domains"]:
            patterns.append(("domain", re.compile(r"\b" + re.escape(d) + r"\b", re.I)))
        for pfx in cfg["ticket_prefixes"]:
            patterns.append(("ticket", re.compile(r"\b" + re.escape(pfx) + r"-\d+\b")))
        for name in cfg["repo_aliases"]:
            patterns.append(("repo", re.compile(r"(?<![\w-])" + re.escape(name) + r"(?![\w-])", re.I)))
        for term in cfg["denylist"]:
            patterns.append(("denylist", re.compile(r"(?<!\w)" + re.escape(term) + r"(?!\w)", re.I)))
        # the alias is local provenance — it must not appear in anything that leaves
        alias = cfg.get("project_alias")
        if alias and not is_placeholder(alias):
            patterns.append(("project-alias", re.compile(r"(?<![\w-])" + re.escape(alias) + r"(?![\w-])", re.I)))
    if args.generic or not args.config:
        patterns.extend(GENERIC_PATTERNS)
    patterns.extend(SECRET_PATTERNS)  # never optional
    hits = 0
    for f in iter_files(args.paths):
        for n, line in enumerate(f.read_text(errors="replace").splitlines(), 1):
            for name, rx in patterns:
                for m in rx.finditer(line):
                    if name == "email" and m.group(0).endswith("@example.com"):
                        continue
                    hits += 1
                    shown = m.group(0)[:12] + "…" if name in SECRET_NAMES else m.group(0)
                    print(f"{f}:{n}: [{name}] {shown}")
    if hits:
        print(f"\nLEAK CHECK FAILED — {hits} hit(s). Nothing leaves the machine until this is clean.")
        return 1
    print("leak check clean")
    return 0


# ---------------------------------------------------------------- env
def cmd_env(args):
    signals = []
    info = {"host": socket.gethostname(), "os": platform.system()}
    if platform.system() == "Darwin":
        r = run(["profiles", "status", "-type", "enrollment"])
        text = r.stdout + r.stderr
        info["mdm"] = text.strip().replace("\n", "; ")
        if re.search(r"MDM enrollment:\s*Yes", text) or re.search(r"Enrolled via DEP:\s*Yes", text):
            signals.append("mdm-enrolled")
    gmail = run(["git", "config", "--global", "user.email"]).stdout.strip()
    info["git_global_email"] = gmail
    if args.config and Path(args.config).exists():
        cfg = load_config(args.config, require_denylist=False)
        dom = gmail.split("@")[-1].lower() if "@" in gmail else ""
        if dom and any(dom == d.lower() or dom.endswith("." + d.lower()) for d in cfg["denied_domains"]):
            signals.append(f"git-global-email-domain:{dom}")
        pid = cfg["personal_identity"].get("email", "").lower()
        if gmail and pid and gmail.lower() != pid and not gmail.endswith("@users.noreply.github.com"):
            signals.append("git-global-email-not-personal")
    r = run(["gh", "auth", "status"])
    gh_text = r.stdout + r.stderr
    hosts = re.findall(r"^(\S+\.\S+)$", gh_text, re.M)
    info["gh_hosts"] = hosts
    for h in hosts:
        if h != "github.com":
            signals.append(f"gh-enterprise-host:{h}")
    active = re.search(r"account (\S+) \(keyring\)\n\s+- Active account: true", gh_text)
    info["gh_active_account"] = active.group(1) if active else None
    klass = "company" if signals else "personal"
    result = {"machine": klass, "signals": signals, **info}
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"machine: {klass}")
        for s in signals:
            print(f"  signal: {s}")
        print(f"  gh active account: {info['gh_active_account']} · hosts: {', '.join(hosts) or 'none'}")
        print(f"  git global email: {gmail or '(unset)'}")
    return 0 if klass == "personal" else 2


# ---------------------------------------------------------------- identity
def git_local_get(repo, key):
    r = run(["git", "-C", repo, "config", "--local", "--get", key])
    return r.stdout.strip() if r.returncode == 0 else None


def backup_path(repo):
    return Path(repo) / ".git" / "upstream-identity-backup.json"


def show_identity(repo, bp):
    for k in IDENTITY_KEYS:
        eff = run(["git", "-C", repo, "config", "--get", k]).stdout.strip() or "(unset)"
        loc = git_local_get(repo, k)
        print(f"  {k:16} effective={eff:45} local={loc if loc is not None else '(unset)'}")
    print(f"  backup: {'present' if bp.exists() else 'none'}")


def cmd_identity(args):
    repo = str(Path(args.repo).resolve())
    if not (Path(repo) / ".git").exists():
        sys.exit(f"error: {repo} is not a git repository root")
    bp = backup_path(repo)
    if args.action == "show":
        show_identity(repo, bp)
        return 0
    if args.action == "save":
        if bp.exists():
            sys.exit(f"error: a backup already exists at {bp} — run `identity restore` first "
                     "(never overwrite a saved identity)")
        snap = {k: git_local_get(repo, k) for k in IDENTITY_KEYS}
        snap["_saved_at"] = now_iso()
        bp.write_text(json.dumps(snap, indent=2))
        print(f"saved local identity -> {bp}")
        for k in IDENTITY_KEYS:
            print(f"  {k:16} {snap[k] if snap[k] is not None else '(unset)'}")
        return 0
    if args.action == "set":
        if not bp.exists():
            sys.exit("error: run `identity save` before `set` — the restore path must exist first")
        if not (args.name and args.email):
            sys.exit("error: --name and --email are required for `set`")
        run(["git", "-C", repo, "config", "--local", "user.name", args.name])
        run(["git", "-C", repo, "config", "--local", "user.email", args.email])
        if args.signingkey:
            run(["git", "-C", repo, "config", "--local", "user.signingkey", args.signingkey])
            run(["git", "-C", repo, "config", "--local", "commit.gpgsign", "true"])
            signing = f"on ({args.signingkey})"
        else:
            run(["git", "-C", repo, "config", "--local", "commit.gpgsign", "false"])
            signing = "off"
        print(f"set local identity: {args.name} <{args.email}> · signing {signing}")
        return 0
    if args.action == "restore":
        if not bp.exists():
            print("nothing to restore (no backup)")
            return 0
        snap = json.loads(bp.read_text())
        for k in IDENTITY_KEYS:
            v = snap.get(k)
            if v is None:
                run(["git", "-C", repo, "config", "--local", "--unset", k])
            else:
                run(["git", "-C", repo, "config", "--local", k, v])
        bp.unlink()
        print("restored local identity:")
        for k in IDENTITY_KEYS:
            print(f"  {k:16} {snap.get(k) if snap.get(k) is not None else '(unset)'}")
        return 0
    return 1


# ---------------------------------------------------------------- log
def cmd_log(args):
    logp = Path(args.root) / "upstream" / "HARVEST-LOG.md"
    logp.parent.mkdir(parents=True, exist_ok=True)
    if not logp.exists():
        logp.write_text("# Harvest log\n\nAppend-only. One line per event: what left this machine, redacted with which "
                        "denylist (hash), with what check result, to where.\n\n")
    parts = [now_iso(), f"id={args.id}", f"event={args.event}"]
    if args.config and Path(args.config).exists():
        parts.append(f"denylist={hashlib.sha256(Path(args.config).read_bytes()).hexdigest()[:12]}")
    if args.sources:
        h = hashlib.sha256()
        for s in args.sources:
            p = Path(s)
            h.update(p.read_bytes() if p.is_file() else s.encode())
        parts.append(f"sources={h.hexdigest()[:12]}({len(args.sources)})")
    if args.check:
        parts.append(f"check={args.check}")
    if args.dest:
        parts.append(f"dest={args.dest}")
    if args.detail:
        parts.append(f"detail={args.detail!r}")
    with logp.open("a") as fh:
        fh.write("- " + " · ".join(parts) + "\n")
    print(f"logged -> {logp}")
    return 0


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".claude", help=".claude directory (default: ./.claude)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("drift", help="diff installed core vs baseline snapshot")
    d.add_argument("--out", help="write one .diff per modified file into this dir")
    d.add_argument("--json", action="store_true")
    d.set_defaults(fn=cmd_drift)

    s = sub.add_parser("sanitize", help="apply redaction rules from upstream.json")
    s.add_argument("--config", required=True)
    s.add_argument("--out", help="write sanitized copies here instead of in place")
    s.add_argument("paths", nargs="+")
    s.set_defaults(fn=cmd_sanitize)

    c = sub.add_parser("check", help="fail if anything confidential remains (secrets always on)")
    c.add_argument("--config")
    c.add_argument("--generic", action="store_true", help="config-free heuristics (intake side)")
    c.add_argument("paths", nargs="+")
    c.set_defaults(fn=cmd_check)

    e = sub.add_parser("env", help="classify this machine: company (exit 2) or personal (exit 0)")
    e.add_argument("--config")
    e.add_argument("--json", action="store_true")
    e.set_defaults(fn=cmd_env)

    i = sub.add_parser("identity", help="scoped git identity swap for the intake commit")
    i.add_argument("action", choices=["show", "save", "set", "restore"])
    i.add_argument("--repo", default=".", help="git repo root (default: CWD)")
    i.add_argument("--name")
    i.add_argument("--email")
    i.add_argument("--signingkey", help="optional personal signing key; signing stays off without it")
    i.set_defaults(fn=cmd_identity)

    lg = sub.add_parser("log", help="append to .claude/upstream/HARVEST-LOG.md")
    lg.add_argument("--id", required=True)
    lg.add_argument("--event", required=True, help="harvested | checked | published | intake")
    lg.add_argument("--config")
    lg.add_argument("--sources", nargs="*", default=[])
    lg.add_argument("--check", choices=["pass", "fail"])
    lg.add_argument("--dest")
    lg.add_argument("--detail")
    lg.set_defaults(fn=cmd_log)

    args = ap.parse_args()
    sys.exit(args.fn(args))


if __name__ == "__main__":
    main()
