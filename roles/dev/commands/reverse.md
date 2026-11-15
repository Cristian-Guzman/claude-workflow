---
name: reverse
version: 0.13.0
description: Reverse-engineer a feature from an app you have no source for, with REA, and turn it into an evidence-backed behavior contract /clarify can plan against. Observes and rebuilds; never transcribes decompiled code.
argument-hint: "PROJ-XXXX --from <url|path> --feature \"<what to replicate>\" [--surface web|electron|apk|native|managed] [--static-only] [--har <path>]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Write
  - Task
  - AskUserQuestion
  - mcp__rea__inspect_web_page
  - mcp__rea__capture_browser_scenario
  - mcp__rea__analyze_web_bundle
  - mcp__rea__export_web_scripts
  - mcp__rea__inspect_web_network_capture
  - mcp__rea__analyze_javascript_application
  - mcp__rea__capture_electron_scenario
  - mcp__rea__trace_application_feature
  - mcp__rea__inspect_android_package
  - mcp__rea__inspect_android_class
  - mcp__rea__inspect_android_method
  - mcp__rea__open_binary
  - mcp__rea__inspect_artifact
  - mcp__rea__analyze_function
  - mcp__rea__inspect_managed_artifact
  - mcp__rea__inspect_analysis_view
  - mcp__rea__get_evidence_bundle
  - mcp__rea__export_evidence_bundle
  - mcp__rea__close_binary
  - mcp__rea__reset_investigation
---
> **Model floor: opus** — behavior inference from partial evidence, plus a legal/scope judgment call. This is guidance, not a pin: the command inherits the session model. If you are a smaller model than the floor, say so in one line at the start and continue.

<objective>
You saw a feature in an app you do not have the source for, and you want the equivalent in this repo.
Observe the real artifact with REA, separate what you **observed** from what you **inferred** from
what stays **unknown**, and write a behavior contract into the ticket state file. `/clarify` then
plans placement against that contract exactly as it plans against a Jira ticket.

This command produces a **specification, never a port.** It does not copy code, pseudocode, strings,
or assets out of the target. The deliverable is a description of behavior that a clean
implementation against this repo's own patterns can satisfy.
</objective>

## 0. Detect Target Repository

Same resolution order as `/clarify`: an explicit repo in `$ARGUMENTS` → the repo owning the CWD →
the repo named in the ticket → ask with `AskUserQuestion`. Set **{REPO_ROOT}** and **{REPO_NAME}**.

Warn in one line if `{REPO_ROOT}/CLAUDE.md` is absent — the contract's "map to our codebase" step
(§6) has nothing to map onto, and the output will be generic.

## 1. Preflight — is REA actually reachable?

Walk this ladder and **stop at the first rung that works.** Do not run diagnostics or setup when the
tools are already there; REA's own skill is explicit that re-running setup before every
investigation is wrong.

| Rung | Check | If it holds |
|---|---|---|
| 1 | `mcp__rea__*` tools are in this session's tool list | Use MCP. Go to §2. |
| 2 | `command -v rea` | Use the CLI (`rea <command> --json`). Go to §2. |
| 3 | `node -v` meets the floor | `npx -y rea-agents@latest <command>` from a directory **outside** `{REPO_ROOT}`. Go to §2. |
| 4 | none of the above | **STOP.** Print the install block below and end. |

```
REA is not reachable from this session.

  Node floor:  22.x >=22.23.4 | 24.x >=24.22.1 | >=26.12.1     (yours: <node -v>)
  Install:     npx rea-agents setup        # registers the MCP server + skill, then restart the client
  Verify:      rea doctor

Native targets additionally need Hopper, Ghidra, IDA or Kuna. Web, Electron/ASAR, APK and
static-JavaScript targets need no analysis engine.
```

Check the Node floor with a comparison, not by eye — `24.9.0` is **below** `24.22.1`, and the
failure it produces later is not obviously a version failure.

If a REA call is blocked by the client, times out, or the connection drops, do **not** repeat an
unchanged call. Read REA's `references/connection-and-recovery.md`, fix the observed blocker, and
resume. A host timeout without a result does not mean the analysis stopped.

## 2. Authorization & Scope Gate — the load-bearing step

This is the step that makes the command usable at work. Classify the target **before** touching it,
and say the classification out loud in the output.

| Class | Signal | What this command does |
|---|---|---|
| **Ours** | Our own shipped build, an old release, a competitor-free internal artifact | Full analysis. This is the easy case: you are allowed to read your own product. |
| **Open source** | The target has a published repo and a license permitting reading | **STOP and redirect.** Reverse-engineering a binary whose source is a `git clone` away is slower, lossier, and pointless. Name the repo and hand off to `/clarify` with the source as the reference. |
| **Third-party proprietary** | A competitor's app, a vendor's binary, a platform app | **Behavior observation only.** Record UI states, timings, network shape, and interaction rules. Do not retain pseudocode, decompiled bodies, string tables, or assets in the contract. |
| **Unclear** | You cannot tell | Ask with `AskUserQuestion` before the first analysis call. |

For **third-party proprietary**, confirm with the user before analyzing, once, in a single question:

> This will analyze `{TARGET}`, which looks like third-party proprietary software. Many EULAs
> restrict reverse-engineering, with carve-outs that vary by jurisdiction and by purpose
> (interoperability, security research, compatibility). Have you confirmed this analysis is within
> scope for this engagement?

If the answer is no or uncertain, stop and offer the alternative that needs no gate: observe the
feature as a **user** — screenshots, click-through, DevTools network panel on a site you are
permitted to use — and write the contract from that. A behavior contract from black-box observation
is weaker on mechanism and just as strong on the states and transitions you actually need to ship.

Record in the contract:

```yaml
target: "<url or path>"
target_identity: "<sha256 of the artifact, or the URL + observation date>"
classification: ours | open-source | third-party | platform
authorization: confirmed-by-user | not-required-ours | black-box-only
```

**Three hard rules for the rest of this command.** They are not style preferences; breaking them
turns a specification into a derivative work:

1. **Never paste decompiled or minified code into the contract, the state file, the commit, or the PR.** Describe what it does.
2. **Never copy assets** — icons, images, fonts, copy strings. Name what is needed; design supplies it.
3. **Never carry over identifiers that only make sense in the target.** Our names come from our codebase.

## 3. Route the Target

Pick the first tool from what the user supplied. `--surface` overrides detection.

| Target | Route | Engine needed |
|---|---|---|
| **URL** (web app) | `inspect_web_page` for structure → `capture_browser_scenario` to drive the interaction → `analyze_web_bundle` / `export_web_scripts` when the mechanism matters | Chrome-family browser |
| **HAR / SAZ** (`--har`) | `inspect_web_network_capture` | none |
| **`.asar` or extracted Electron/JS tree** | `analyze_javascript_application` with `"detail": "summary"` → `capture_electron_scenario` for runtime | none for static |
| **`.apk`** | `inspect_android_package` → `inspect_android_class` → `inspect_android_method` | none |
| **`.app` / `.exe` / ELF** | `open_binary` → `inspect_artifact` → `analyze_function` | **Hopper / Ghidra / IDA / Kuna** |
| **.NET assembly** | `inspect_managed_artifact` | none |
| **Archive / package** (ZIP, DMG, IPA, MSIX) | `open_binary` → `inspect_artifact`, `detail: "summary"` first | none |

If the route needs a native engine and none is configured, say so in one line and fall back to the
black-box path from §2 rather than ending with nothing. A UI feature almost never needs the engine.

**For a desktop app whose feature is a UI interaction, prefer runtime observation over
decompilation.** `capture_browser_scenario` / `capture_electron_scenario` answer "what does this
button do" directly; the native path answers it slowly and at a legal cost.

## 4. Observe — summary-first, always

REA's paging discipline, which this command must not shortcut:

- Call analysis tools with `"detail": "summary"` when the target's size is unknown or large. Read the retained `parent_evidence_id` with `inspect_analysis_view` for the parts you actually need.
- **Never request `"detail": "complete"` just to have the whole dossier inline.** It is the most common way to blow the context on a feature that needed three fields.
- `trace_application_feature` only **after** a seed is known. A broad bidirectional trace expands unrelated containment and is the second most common way to blow the context.
- Do not repeat an identical call without a changed input or a resolved blocker.
- On `resource_constraint` with `details.resource: "transport"`, do not re-run the producer — page the retained evidence, or `export_evidence_bundle` to a path.
- A truncated-looking result is incomplete, not canonical JSON. Page the parent ID instead of parsing the preview.

**Never write that static analysis observed execution.** "The handler calls `fetch` on mount" is an
observation about code; "the request fires on mount" is a claim about runtime, and needs a runtime
capture to earn.

Keep a running ledger as you go — one row per question, with the Evidence ID that answered it and
what is still open. This becomes §5.

## 5. Write the Behavior Contract

The deliverable. Every row carries its evidence class, because that is what `/verify` scores later
and what tells the reader which rows are safe to build on.

```markdown
## Behavior Contract — {FEATURE}

Target: `{TARGET}` · identity `{sha256|url+date}` · classification **{CLASS}**
Evidence: REA session `{session}`, bundle `{path or "not exported"}`

| # | Behavior | Evidence class | Source | Confidence |
|---|----------|----------------|--------|-----------|
| 1 | Opens on click, 180ms ease-out slide from the right | observed (runtime) | `ev_a1b2` capture_browser_scenario | HIGH |
| 2 | Closes on ESC and on overlay click | observed (runtime) | `ev_a1b2` | HIGH |
| 3 | Results debounce ~250ms before the request | inferred (timing, 4 samples) | `ev_c3d4` | MED |
| 4 | Ranking is server-side | unknown — response is opaque | — | — |

### Interaction states

| State | Trigger | Visual | Evidence |
|---|---|---|---|
| default / hover / focus-visible / active / disabled / loading / empty / error | … | … | … |

### Unknowns that change the build
- Row 4: if ranking is server-side, our version needs a BFF endpoint, not a client sort. **Blocks estimation.**
```

Three rules for the contract:

- **Every row is observed, inferred, or unknown.** No fourth class, and "probably" is `inferred`.
- **An unknown that changes the implementation is a question, not a footnote.** Surface it in §7's hand-off as a blocker, the way `/clarify` surfaces a PM question.
- **Enumerate the states, including the ones you could not reach.** A target's disabled and error states are usually unobservable without its backend — say so rather than silently shipping only the happy path. This is the leak `/clarify` §2 flags for Figma, and it is worse here: a running app shows you the default state most eagerly of all.

For a UI feature, the per-state rows are the same shape `/clarify --visual-spec` produces, so
`/verify` and `/ui-fidelity` can consume them with no translation.

## 6. Map to Our Codebase

A contract that does not name our files is a wish. Classify the feature by atomic level, then find
what already exists — the goal is the smallest new surface that satisfies §5, not a faithful clone
of the target's architecture.

1. **Classify:** atom | molecule | organism | template | page. Feature-local by default; promote to shared only when a second consumer exists today.
2. **Find the reuse:** grep `{REPO_ROOT}` for existing components that already cover part of the contract. Read `.claude/codebase-patterns.md` and the repo profile first — the answer is often "we have this, it needs one prop."
3. **Name the gap:** per contract row, either the existing component that satisfies it or the new thing needed.
4. **Flag the divergences you are choosing on purpose.** Where our stack, design system, or a11y baseline says something different from the target, our side wins and the contract records why. Match the behavior, not the pixels — ship close and iterate after QA.

```markdown
### Rebuild Map
| Contract row | Our implementation | Status |
|---|---|---|
| 1, 2 | `components/ui/Drawer.tsx` — has slide + ESC already | reuse as-is |
| 3 | `hooks/useDebouncedQuery.ts` — 300ms, ours stays 300ms | reuse, divergence recorded |
| 4 | **blocked** — needs the ranking question answered | — |
```

## 7. Persist and Hand Off

Write `{REPO_ROOT}/.claude/tickets/{TICKET}-reverse.md` (or `{slug}-reverse.md` with no tracker):

```yaml
---
kind: reverse
status: contract
ticket: PROJ-XXXX | null
slug: command-palette-button
target: "<url|path>"
target_identity: "<sha256|url+date>"
classification: ours | open-source | third-party | platform
authorization: confirmed-by-user | not-required-ours | black-box-only
evidence_bundle: "<path|null>"
created: <ISO8601>
updated: <ISO8601>
---
```

Body: §5's contract, §6's rebuild map, and the open unknowns. `kind: reverse` is load-bearing — the
state index archives it as a terminal investigation artifact and keeps it as a prior-art source,
instead of indexing a `status: unknown` zombie.

Then print the hand-off, and stop:

```
Contract written: .claude/tickets/{TICKET}-reverse.md
  {N} observed · {M} inferred · {K} unknown ({B} of them blocking)

Next:  /clarify {TICKET}          # reads the contract as DESIGN_CASE = external
```

**This command never edits product code, never creates a branch, and never opens a PR.** It stops at
the contract, the way `/clarify` stops at the blueprint. If the unknowns include a blocking row,
say so in the hand-off rather than letting `/clarify` plan around a hole.

## 8. Close the Investigation

- `close_binary` for any native session once its engine is no longer needed.
- `export_evidence_bundle` to `{REPO_ROOT}/.claude/evidence/{TICKET}/` **only** for classification `ours` or `open-source`. For a third-party target, do not commit an evidence bundle — it contains the artifact's internals. Note the bundle path as local-only in the contract, and keep `.claude/evidence/` in `.gitignore`.
- `reset_investigation` at the end. Retention is bounded and is not persistence; an un-exported session is gone on reconnect.

## Guardrails

- **Specification, not a port.** If the output contains target code, the command failed.
- **Observed, inferred, unknown — never blurred.** A contract that reads as uniformly confident is the one that costs a day in QA.
- **The engine is the last resort, not the first.** Runtime observation answers UI questions faster, cheaper, and with a smaller legal surface than decompilation.
- **Stop at the contract.** Placement, phases, and tests belong to `/clarify` and `/ticket`, which already do them better than a second implementation here would.
