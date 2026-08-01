---
name: ui-fidelity
version: 0.6.0
model: "opus[1m]"
description: Ad-hoc design-fidelity check — compare a UI implementation against its design reference for the current surface. Dimension-by-dimension gap list with scoped fixes, live-data hardening pass, and per-surface manual QA checklist. Reports only, never edits.
argument-hint: "[repo | PROJ-XXXX] [design ref: URL or screenshot path]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Task
  - AskUserQuestion
---

# /ui-fidelity

Ad-hoc design-fidelity check: compare a UI implementation against its design reference for the current surface, get a dimension-by-dimension gap list with scoped fixes, a live-data hardening pass, and a per-surface manual QA checklist.

This is the thin, direct entry point to the `ui-fidelity` agent. You normally don't call it by hand — `/clarify` runs it up-front (to produce the design contract before coding) and `/verify` runs it in its visual_compare step. Use `/ui-fidelity` for the "just check this one screen against the design right now" case, mid-iteration (e.g. during in-Word/in-Docs QA).

<objective>
Detect the target repo/surface, gather the design reference + implementation files, invoke the `ui-fidelity` agent, and present its report. Never edits code — it reports. Applying fixes is a separate, confirmed step.
</objective>

<process>

## 0. Detect repo & surface
- Parse `$ARGUMENTS` for a repo hint or ticket id (PROJ-XXXX). Else use CWD (must be at least one level under `$WORKSPACE_ROOT/`).
- Resolve **surface** from the repo (the agent's Surface adapters table is canonical): `addin-fe`→`word-addin` (or `web` for `app/(web)` routes), `gdocs-addin`→`gas-addin`, `ios-app`→`swiftui`, `web-app`→`web-legacy`.
- If ambiguous, ask with `AskUserQuestion`.

## 1. Gather inputs
- **Design reference** (in priority order): an existing `{repo}/.claude/tickets/PROJ-XXXX-visual-spec.yaml`; else a sibling-surface component the ticket says to match (e.g. the GDocs add-in component for a Word ticket); else a Figma URL / screenshot path the user provides. If none found, ask the user for the reference.
- **Impl files**: from the ticket's `## Files Modified` / `## File Placement` (state file or clarify blueprint), or from `$ARGUMENTS`, or the `git diff --name-only {base}...HEAD` UI files. If none, ask which screen/component.
- **Locked decisions**: read the ticket state file's `## Decisions Made` and pass them through so the agent doesn't propose reverting them (e.g. "keep 2.0 badge", "no filter tabs").

## 2. Invoke the agent
```
Task(
  subagent_type: "ui-fidelity",
  description: "UI fidelity for {TICKET_ID}",
  prompt: "Check design fidelity.
    ticket_id: {PROJ-XXXX}
    repo_root: {REPO_ROOT}
    surface: {surface}
    design_reference: {path | url | visual-spec.yaml}
    impl_files: {list}
    locked_decisions: {from Decisions Made}
    mode: diff"
)
```
Prefer a `{repo}/.claude/agents/ui-fidelity.md` override if one exists (repo-specific surface tweaks); else the workspace agent above.

## 3. Present the report verbatim
Show the agent's three sections (contract / gaps / live-data) + the manual QA checklist. Then:
- If gaps exist, list the scoped fixes and ask whether to apply them (a normal edit step — confirm before editing, and shared-component fixes need explicit OK per the agent's scope guard).
- Always remind: on sideload/iOS surfaces, the visual can only be confirmed by the human in the real app — hand off the manual QA checklist.

</process>

## Flags
- `--contract` — produce only the target contract (pre-implementation), don't diff. Same as how `/clarify` calls it.
- `--reference <path|url>` — override the design reference.

## Related
- Auto-invoked by: `/clarify` (contract mode, pre-code) · `/verify` (diff mode, visual_compare) · `/qa` (manual checklist)
- Agent: `$WORKSPACE_ROOT/.claude/agents/ui-fidelity.md`
- Lessons: [[feedback_design_fidelity_live_data]], [[feedback_no_preview_screenshot_loop]], [[feedback_match_visual_target_not_pixel_perfect]]
