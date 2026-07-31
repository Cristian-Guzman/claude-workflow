#!/usr/bin/env python3
"""
verify-score.py — compute the /verify confidence score from a gate table.

The score is ARITHMETIC over the gate table in a verification report; the
model gathers evidence, this script grades it. Never hand-write the number.
Design: docs/verify-confidence-score.md

Usage:
    verify-score.py REPORT.md [--root REPO_ROOT]

Gate table format (markdown, header row required):
    | Gate | State | Receipt / Owner |
    |------|-------|-----------------|
    | Unit tests [BLOCKING] | PASS | jest exit 0 — "47 passed, 47 total" |
    | Visual: sidebar       | UNVERIFIED | human: in-app QA at 320px |

Tags in the Gate cell:
    [BLOCKING]  — FAIL caps the score at 30%
    [CAP85]     — quality finding (legacy clamp HIGH->MEDIUM); FAIL/UNVERIFIED caps at 85%

Rules (fail-closed):
    - PASS/FAIL rows need a substantive receipt; a PASS without one is scored FAIL.
    - UNVERIFIED rows must name a human step ("human:" owner); they cap at 70%.
    - Receipt spot-check: quoted "evidence" + a path:line ref are re-checked with
      grep -F when the file exists under --root; a mismatch caps at 30%.
    - Rows whose State contains "excluded" are dropped from the denominator.

Exit codes: 0 = score >= 70, 1 = 31..69, 2 = <= 30, 3 = no gate table found.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

STATES = {"PASS", "FAIL", "UNVERIFIED"}
MIN_RECEIPT_LEN = 6  # anything shorter is decoration, not evidence

ROW = re.compile(r"^\s*\|(.+)\|\s*$")
REF = re.compile(r"([\w./\-\[\]()]+\.[A-Za-z]{1,10}):(\d+)")
QUOTE = re.compile(r'"([^"]{4,})"')


def parse_rows(text):
    """Yield (gate, state, receipt) from the first table with a Gate|State header."""
    rows, in_table = [], False
    for line in text.splitlines():
        m = ROW.match(line)
        if not m:
            in_table = False if in_table and rows else in_table
            continue
        cells = [c.strip() for c in m.group(1).split("|")]
        if len(cells) < 3:
            continue
        head = cells[0].lower()
        if head == "gate":
            in_table = True
            continue
        if in_table and set(cells[1]) <= set("-: "):
            continue  # separator row
        if in_table:
            rows.append((cells[0], cells[1].upper(), " | ".join(cells[2:]).strip()))
    return rows


def spot_check(receipt, root):
    """Re-check quoted evidence against a cited file. Returns (ok, detail)."""
    ref = REF.search(receipt)
    quote = QUOTE.search(receipt)
    if not (ref and quote):
        return True, None  # nothing checkable — presence rules still apply
    path = root / ref.group(1)
    if not path.is_file():
        return True, None  # can't check (command output, deleted file) — not a mismatch
    r = subprocess.run(["grep", "-Fq", quote.group(1), str(path)])
    if r.returncode != 0:
        return False, f'evidence "{quote.group(1)[:40]}..." not found in {ref.group(1)}'
    return True, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("--root", default=".", help="repo root for receipt spot-checks")
    args = ap.parse_args()
    root = Path(args.root).resolve()

    rows = parse_rows(Path(args.report).read_text(encoding="utf-8", errors="replace"))
    gates = []
    for gate, state, receipt in rows:
        if "EXCLUDED" in state or "(EXCLUDED" in state:
            continue
        state = next((s for s in STATES if s in state), None)
        if state is None:
            continue  # not a gate row (legend, notes)
        gates.append({"gate": gate, "state": state, "receipt": receipt,
                      "blocking": "[BLOCKING]" in gate, "cap85": "[CAP85]" in gate})
    if not gates:
        print("ERROR: no gate table found (header must be | Gate | State | Receipt ... |)")
        sys.exit(3)

    caps, flags = [], []
    for g in gates:
        if g["state"] in ("PASS", "FAIL"):
            if len(g["receipt"]) < MIN_RECEIPT_LEN:
                if g["state"] == "PASS":
                    g["state"] = "FAIL"  # unevidenced claim never scores
                flags.append(f"{g['gate']}: no receipt — scored FAIL")
            else:
                ok, detail = spot_check(g["receipt"], root)
                if not ok:
                    caps.append((30, f"{g['gate']}: receipt mismatch ({detail})"))
        if g["state"] == "FAIL" and g["blocking"]:
            caps.append((30, f"[BLOCKING] {g['gate']} FAIL"))
        if g["state"] == "UNVERIFIED":
            caps.append((70, f"{g['gate']} awaits human confirmation"))
            if "human" not in g["receipt"].lower():
                flags.append(f"{g['gate']}: UNVERIFIED but no human step named")
        if g["cap85"] and g["state"] != "PASS":
            caps.append((85, f"[CAP85] quality finding: {g['gate']}"))

    passed = sum(1 for g in gates if g["state"] == "PASS")
    raw = round(100 * passed / len(gates))
    score = min([raw] + [c for c, _ in caps]) if caps else raw
    band = ("SHIP" if score >= 90 else "MEDIUM — human/quality caps" if score >= 70
            else "GAPS" if score > 30 else "WILL BREAK")

    print(f"Score: {score}% ({passed}/{len(gates)} gates) — {band}")
    if caps:
        worst = min(caps)[0]
        print(f"Caps applied (worst wins -> {worst}%):")
        for cap, why in sorted(set(caps)):
            print(f"  - cap {cap}%: {why}")
    for f in flags:
        print(f"  ! {f}")
    sys.exit(0 if score >= 70 else 1 if score > 30 else 2)


if __name__ == "__main__":
    main()
