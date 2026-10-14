#!/usr/bin/env python3
"""
render-walkthrough.py — render a ticket state file as a sanitized, shareable walkthrough.

Reads one state file (core/docs/state-file-schema.md: YAML frontmatter + `## Event Log`
lines `- [HH:MM] …`) and emits markdown:

  1. a step table   | step | actor | event | artifact written |
  2. a Process Summary table — the /pr-creation §8 fields derived MECHANICALLY from the Event Log
     (sessions, phases, fix_iterations, debug_sessions, commits, first_event_to_pr_days,
     ui_iteration), side by side with whatever /pr-creation recorded. A field the log cannot
     yield is `unrecorded` — never estimated.
  3. the `## Closeout` AUTO region, verbatim, when the file has one.

Sanitization is not optional. The rule builder, rule applier and leak check are IMPORTED
from upstream.py (same directory) — never re-implemented here. With --config the project
denylist/aliases are applied and checked; without it only the config-free heuristics and
the always-on secret patterns run. The check runs on the rendered text BEFORE anything is
written or printed; one hit → exit 1 and no output.

Usage:
    render-walkthrough.py STATE.md [--config .claude/upstream.json] [--root .claude]
                                   [--out FILE]

Exit codes: 0 rendered · 1 leak check failed (or fail-closed config) · 2 input error.

Derivation rules (deterministic; the whole point is that they cannot be prettified):
  actor      explicit `<actor>:` prefix when it is a `/command`, `user`, or a core agent;
             otherwise inferred from the /ticket Event Logging vocabulary (Classified as,
             Plan approved, Hit issue:, …); otherwise `—`.
  artifact   paths / `PR #n` / commit shas / the branch after "Branched … →" found in the
             line; a few vocabulary fallbacks (Classified → ## Classification, Plan
             approved → ## Plan Summary, /pr-creation → ## Process Summary, /ci-check Merged →
             frontmatter merged_at, /learn → ## Closeout); otherwise `—`.
  sessions   `Classified as` lines + /resume-ticket lines.
  phases     body rows of the `## Implementation Progress` table, else distinct
             `Phase N done` events.
  fix_iter   `Hit issue:` + QA-round/bounce + review-fix lines.
  commits    only git knows (`rev-list --count`); never derived from the log → unrecorded.
  days       first event date → first `/pr-creation … PR #n` event date, only when event lines
             carry a `[YYYY-MM-DD HH:MM]` stamp; else unrecorded.
"""
import argparse
import contextlib
import io
import os
import re
import sys
import tempfile
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import upstream  # noqa: E402  (the sanitizer; co-located in core/scripts → .claude/scripts)
except ImportError:
    sys.exit("error: upstream.py not found next to render-walkthrough.py — the sanitizer is required; "
             "nothing is rendered without it")

EVENT_RX = re.compile(r"^- \[(?:(\d{4}-\d{2}-\d{2}) )?(\d{1,2}:\d{2})\]\s*(.*\S)\s*$")
CORE_AGENTS = {"codebase-investigator", "jira-context-loader", "commit-drafter", "contract-verifier",
               "pr-branch-reviewer", "ui-fidelity", "verifier"}
EXPLICIT_ACTOR_RX = re.compile(r"^(/[a-z][a-z0-9-]*|user|[a-z][a-z0-9-]*):\s+(.*)$")

# ticket.md §1.1 "Event Logging" vocabulary → the command that writes that line
VOCAB_ACTOR = [
    (re.compile(r"^(Classified as|Plan approved|Following pattern from|AC\d+ done|Hit issue:|Workaround:|"
                r"Debug session opened:|Tests written|Phase \d+ done|Re-tiered|Branched|TDD:|Pattern confirmed)"), "/ticket"),
    (re.compile(r"^Debug resolved:"), "/project-debug"),
    (re.compile(r"^Resumed\b"), "/resume-ticket"),
    (re.compile(r"^\[qa-confirmed via"), "user"),
]

PATH_RX = re.compile(r"`([^`]*(?:/[^`]*|\.(?:md|ts|tsx|js|jsx|json|ya?ml|py|sh|css|scss|go)))`")
BARE_CLAUDE_PATH_RX = re.compile(r"(?<![\w`])(\.claude/[\w./-]+)")
PR_RX = re.compile(r"\bPR #\d+")
SHA_RX = re.compile(r"\b[0-9a-f]{7,40}\b")
BRANCH_RX = re.compile(r"^Branched\b.*?→\s*(\S+)")
DEBUG_SLUG_RX = re.compile(r"\.claude/debug/([\w-]+)\.md")
FIX_RX = re.compile(r"^Hit issue:|\bQA[- ]?(?:round|bounce)|\bqa-bounce\b|\breview[- ]fix|^/review-comments:", re.I)
TABLE_SEP_RX = re.compile(r"^\|\s*:?-{2,}")


# ---------------------------------------------------------------- parsing
def parse_frontmatter(lines):
    """Minimal YAML: `key: value` at indent 0, one level of 2-space nesting. Enough for the schema."""
    if not lines or lines[0].strip() != "---":
        return {}, lines
    fm, parent, i = {}, None, 1
    while i < len(lines) and lines[i].strip() != "---":
        raw = lines[i]
        i += 1
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        key, _, val = raw.strip().partition(":")
        val = val.strip().strip('"').strip("'")
        if indent == 0:
            if val == "":
                fm[key], parent = {}, key
            else:
                fm[key], parent = val, None
        elif parent is not None and isinstance(fm.get(parent), dict):
            fm[parent][key] = val
    return fm, lines[i + 1:]


def split_sections(body):
    """H2 title → list of lines (title keeps any suffix like 'Process Summary (round 3)')."""
    sections, title = {}, None
    for ln in body:
        if ln.startswith("## "):
            title = ln[3:].strip()
            sections.setdefault(title, [])
        elif title is not None:
            sections[title].append(ln)
    return sections


def find_section(sections, prefix, last=False):
    keys = [k for k in sections if k.startswith(prefix)]
    if not keys:
        return None
    return sections[keys[-1] if last else keys[0]]


def parse_events(lines):
    events = []
    for ln in lines or []:
        m = EVENT_RX.match(ln)
        if m:
            events.append({"date": m.group(1), "time": m.group(2), "text": m.group(3)})
    return events


# ---------------------------------------------------------------- derivation
def split_actor(text):
    m = EXPLICIT_ACTOR_RX.match(text)
    if m and (m.group(1).startswith("/") or m.group(1) == "user" or m.group(1) in CORE_AGENTS):
        return m.group(1), m.group(2)
    for rx, actor in VOCAB_ACTOR:
        if rx.match(text):
            return actor, text
    return "—", text


def artifacts_for(actor, text):
    found = []

    def add(x):
        if x and x not in found:
            found.append(x)

    for m in PATH_RX.finditer(text):
        add(f"`{m.group(1)}`")
    for m in BARE_CLAUDE_PATH_RX.finditer(text):
        add(f"`{m.group(1)}`")
    for m in PR_RX.finditer(text):
        add(m.group(0))
    if re.search(r"\bcommit", text, re.I):
        for m in SHA_RX.finditer(text):
            add(f"commit {m.group(0)}")
    m = BRANCH_RX.match(text)
    if m:
        add(f"branch `{m.group(1)}`")
    if text.startswith("Classified as"):
        add("## Classification")
    elif text.startswith("Plan approved"):
        add("## Plan Summary")
    elif text.startswith("Tests written"):
        add("tests")
    if actor == "/pr-creation" and PR_RX.search(text):
        add("## Process Summary")
    if actor == "/ci-check" and re.search(r"\bmerged\b", text, re.I):
        add("frontmatter: merged_at · outcome")
    if actor == "/learn":
        add("## Closeout")
    return ", ".join(found) if found else "—"


def table_body_rows(lines):
    rows = [ln for ln in lines or [] if ln.lstrip().startswith("|")]
    return [r for r in rows[1:] if not TABLE_SEP_RX.match(r.strip())] if rows else []


def derive_summary(events, sections):
    texts = [e["text"] for e in events]
    stripped = [split_actor(t) for t in texts]

    sessions = sum(1 for t in texts if t.startswith("Classified as")) + \
        sum(1 for a, t in stripped if a == "/resume-ticket" or t.startswith("Resumed"))

    phase_rows = table_body_rows(find_section(sections, "Implementation Progress"))
    if phase_rows:
        phases = str(len(phase_rows))
    else:
        nums = {m.group(1) for t in texts for m in [re.match(r"^Phase (\d+) done", t)] if m}
        phases = str(len(nums)) if nums else "unrecorded"

    fix_iterations = sum(1 for a, t in stripped if FIX_RX.search(t))

    slugs = []
    for t in texts:
        for m in DEBUG_SLUG_RX.finditer(t):
            if m.group(1) not in slugs:
                slugs.append(m.group(1))

    days = "unrecorded"
    dated = [e for e in events if e["date"]]
    if dated:
        first = date.fromisoformat(dated[0]["date"])
        for e in events:
            a, t = split_actor(e["text"])
            if a == "/pr-creation" and PR_RX.search(t) and e["date"]:
                days = str((date.fromisoformat(e["date"]) - first).days)
                break

    ui = next((t for t in texts if "ui-iteration" in t), None)

    return {
        "sessions": str(sessions) if sessions else "unrecorded",
        "phases": phases,
        "fix_iterations": str(fix_iterations),
        "debug_sessions": ", ".join(slugs) if slugs else "none",
        "commits": "unrecorded",
        "first_event_to_pr_days": days,
        "ui_iteration": ui if ui else "n/a",
    }


def recorded_summary(sections):
    lines = find_section(sections, "Process Summary", last=True)
    rec = {}
    for ln in lines or []:
        m = re.match(r"^-\s*([a-z_]+):\s*(.*\S)\s*$", ln)
        if m:
            rec[m.group(1)] = m.group(2)
    return rec


def closeout_region(sections):
    lines = find_section(sections, "Closeout")
    if not lines:
        return None
    text = "\n".join(lines)
    m = re.search(r"<!-- AUTO:CLOSEOUT START -->\n(.*?)\n<!-- AUTO:CLOSEOUT END -->", text, re.S)
    return m.group(1).strip() if m else "\n".join(ln for ln in lines if ln.strip()).strip()


# ---------------------------------------------------------------- render
def cell(s):
    return s.replace("|", "\\|")


def render(fm, sections, events, src_name):
    ticket = fm.get("id") or fm.get("ticket") or "PROJ-?"
    cls = fm.get("classification") if isinstance(fm.get("classification"), dict) else {}
    tier = cls.get("tier")
    if not tier:
        for ln in find_section(sections, "Classification") or []:
            m = re.search(r"Tier:\s*(\w+)", ln)
            if m:
                tier = m.group(1)
                break
    out = [f"# Walkthrough — {ticket} · {tier or 'tier unrecorded'} · {fm.get('repo', 'repo unrecorded')} · "
           f"status {fm.get('status', 'unrecorded')}",
           "",
           f"_Rendered by `render-walkthrough.py` from `{src_name}`. Every cell below is derived from the "
           f"state file by the rules in the script header; nothing is hand-edited._",
           ""]
    if fm.get("summary"):
        out += [f"> {fm['summary']}", ""]
    out += ["## Steps", "", "| step | actor | event | artifact written |", "|---|---|---|---|"]
    for i, e in enumerate(events, 1):
        actor, text = split_actor(e["text"])
        stamp = f"{e['date']} {e['time']}" if e["date"] else e["time"]
        out.append(f"| {i} | {cell(actor)} | [{stamp}] {cell(text)} | {cell(artifacts_for(actor, text))} |")
    if not events:
        out.append("| — | — | no `- [HH:MM]` lines under `## Event Log` | — |")

    derived, rec = derive_summary(events, sections), recorded_summary(sections)
    out += ["", "## Process Summary", "", "| field | derived from Event Log | recorded by /pr-creation |", "|---|---|---|"]
    for k, v in derived.items():
        out.append(f"| {k} | {cell(v)} | {cell(rec.get(k, '—'))} |")
    out += ["", "_`commits` and `first_event_to_pr_days` need git and dates; an Event Log stamped only "
            "`[HH:MM]` cannot yield them, so they read `unrecorded` here and `/pr-creation` records them at PR time._"]

    co = closeout_region(sections)
    if co:
        out += ["", "## Closeout", "", co]
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- sanitize + check (imported)
def sanitize_and_check(text, cfg_path, root):
    counts = {}
    if cfg_path:
        cfg = upstream.load_config(cfg_path)  # fail-closed on an empty/placeholder denylist
        text, counts = upstream.apply_rules(text, upstream.build_rules(cfg, root))
    with tempfile.NamedTemporaryFile("w", suffix=".md", prefix="walkthrough-", delete=False) as tmp:
        tmp.write(text)
        tmp_path = tmp.name
    buf = io.StringIO()
    try:
        ns = argparse.Namespace(config=cfg_path, generic=True, paths=[tmp_path], root=root)
        with contextlib.redirect_stdout(buf):
            rc = upstream.cmd_check(ns)
    finally:
        os.unlink(tmp_path)
    return text, counts, rc, buf.getvalue().replace(tmp_path, "<rendered>")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("state_file")
    ap.add_argument("--config", help="upstream.json — project denylist/aliases (strongly recommended)")
    ap.add_argument("--root", default=".claude", help=".claude directory, as upstream.py expects (default: ./.claude)")
    ap.add_argument("--out", help="write here instead of stdout (only written when the leak check is clean)")
    args = ap.parse_args()

    src = Path(args.state_file)
    if not src.is_file():
        sys.exit(f"error: state file not found: {src}")
    lines = src.read_text(errors="replace").splitlines()
    fm, body = parse_frontmatter(lines)
    sections = split_sections(body)
    events = parse_events(find_section(sections, "Event Log"))
    if not events:
        print(f"warning: no Event Log entries in {src}", file=sys.stderr)

    rendered = render(fm, sections, events, src.name)
    if not args.config:
        print("notice: no --config — generic heuristics + secret patterns only; pass --config "
              ".claude/upstream.json to apply and check the project denylist", file=sys.stderr)
    text, counts, rc, report = sanitize_and_check(rendered, args.config, args.root)
    if rc != 0:
        sys.stderr.write(report)
        sys.stderr.write("render-walkthrough: nothing written.\n")
        return 1

    if args.out:
        Path(args.out).write_text(text)
        redacted = ", ".join(f"{k}={v}" for k, v in sorted(counts.items())) or "nothing to redact"
        print(f"rendered {len(events)} steps → {args.out} · sanitized: {redacted} · leak check clean", file=sys.stderr)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
