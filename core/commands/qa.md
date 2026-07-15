---
name: qa
version: 0.4.0
description: Generate a QA guide and optionally run it live with Playwright. Auto-detects backend tickets and produces a runtime-evidence guide instead (deploy confirmation, trigger, data inspection, logs). Also offers a CSS preview harness for sideload-only surfaces (Word Add-in, Google Docs Add-in) where Playwright can't drive the real app.
argument-hint: "PROJ-XXXX [--live] [--guide-only] [--no-preview]"
allowed-tools:
  - Read
  - Write
  - Bash
  - Glob
  - Grep
  - Task
  - AskUserQuestion
---

<objective>
Generate a practical QA guide for ticket $ARGUMENTS, then optionally execute it live using Playwright.

**When to use /qa vs /verify:**

- **`/verify`** is the source of truth for AC verification — it now runs mechanical visual checks (Playwright `getComputedStyle()` readback, viewport sweep at 320/450/1280, css_token_compliance, narrow-viewport-specific Word Add-in checks). Use `/verify` when the question is "did we meet the AC."
- **`/qa`** generates a HUMAN-DRIVEN exploratory guide — sideload steps, edge cases that need judgment, content-shape variations, accessibility flows that require a screen reader, sideloaded-Word-only flows. Use `/qa` when the question is "what should I poke at to find bugs the ACs didn't cover."

If you only need AC verification, run `/verify` instead. `/qa` complements it for exploratory and human-judgment cases.

Two modes:
- **`--guide-only`** (or default if Playwright/Chrome debug not available): Generate a text QA checklist
- **`--live`** (or default if Playwright + Chrome debug ARE available): Generate the guide AND run each step live, reporting pass/fail per AC

When running live, Playwright connects to your Chrome debug session (port 9222) and navigates your actual dev server pages with your logged-in session.
</objective>

<process>

## 0. Detect Target Repository

1. **Parse $ARGUMENTS** for repo hints or ticket numbers
2. **Check current working directory** — if CWD is inside a sub-repo of `$WORKSPACE_ROOT/{repo-name}/`, use that repo. **IMPORTANT:** `$WORKSPACE_ROOT/` itself is NOT a valid target — it's the workspace root. Only match if CWD is at least one level deeper.
3. **Check which repos have the ticket state file:**
   ```bash
   for dir in "$WORKSPACE_ROOT"/*/; do
     [ -f "$dir/.claude/tickets/PROJ-XXXX.md" ] && echo "$(basename $dir): $dir"
   done 2>/dev/null
   ```
4. **If still ambiguous**, list repos and **always ask the user** using `AskUserQuestion`

Load repo config:
- Read `{REPO_ROOT}/CLAUDE.md` for architecture, dev commands, URLs
- Check for `{REPO_ROOT}/.claude/codebase-patterns.md` → read if exists
- Check for `{REPO_ROOT}/.claude/testing-patterns.md` → read if exists

**If `{REPO_ROOT}/CLAUDE.md` does NOT exist**, warn the user:
> "This repo ({REPO_NAME}) doesn't have a CLAUDE.md. I won't know the dev command, base URL, or architecture. The QA guide will be based solely on code analysis — environment setup and URL mapping will be missing."

## 1. Gather Ticket Context

Parse ticket number (PROJ-XXXX) from $ARGUMENTS.

### 1a. Read ticket state file (if exists)

Check for `{REPO_ROOT}/.claude/tickets/PROJ-XXXX.md`. If found, extract: acceptance criteria, files modified, plan summary, decisions made.

### 1b. Fetch from Jira (if no state file or state file lacks detail)

Try in order:
1. **MCP**: Use `mcp__atlassian__getJiraIssue` to read the ticket
2. **CLI fallback**: `jira issue view PROJ-XXXX --plain`
3. **Manual fallback**: Ask the user to paste the ticket description and ACs

Extract: summary, description, acceptance criteria, issue type (Bug/Story/Task/Improvement), and linked tickets.

### 1c. Classify ticket type

- **Bug** — something is broken; QA verifies the fix
- **Feature** — something new; QA verifies it exists and works
- **Improvement** — something existing changed; QA verifies the enhancement
- **Refactor** — internal change; QA verifies no visible regressions

### 1d. Detect QA surface (auto — no flags, same philosophy as /clarify and /verify)

Classify **{QA_SURFACE}** ∈ `ui | backend | mixed`:

- **backend** — REPO_TYPE is backend (`backend-go`, `backend-bff`, `backend-service` — e.g. backend-services, mail-service, api-bff, documents-api, billing-service, chat-service) OR every modified file is non-UI (`*.go`, `src/routes/`, `src/services/`, migrations, protos). URLs/screens/Playwright are meaningless here.
- **ui** — the existing default: modified files render pixels.
- **mixed** — cross-repo or full-stack ticket: run BOTH paths (backend guide for the service repo, UI guide for the consumer).

`backend` → run **Section 3-B** below and SKIP Steps 3–8 (route mapping, preview harness, live Playwright — all N/A). `ui` → continue with Step 3 as before.

## 2. Analyze Code Changes

### 2a. Get modified files

First resolve the repo's base branch — **never hardcode `main`** (some repos use a non-default base branch recorded in the repo profile — e.g. api-bff/web-app use `develop-v2`, billing-service/addin-fe/gdocs-addin use `develop`; ios-app uses `main`). Use `base_branch` from `repo-profiles/{REPO}.yaml`, falling back to `git -C {REPO_ROOT} rev-parse --abbrev-ref origin/HEAD | sed 's@^origin/@@'`:

```bash
BASE_BRANCH=$(awk -F': ' '/^base_branch:/{print $2}' .claude/repo-profiles/{REPO}.yaml 2>/dev/null)
BASE_BRANCH=${BASE_BRANCH:-$(git -C {REPO_ROOT} rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's@^origin/@@')}
git -C {REPO_ROOT} diff --name-only "${BASE_BRANCH}...HEAD"
```

If no diff against the base branch:
```bash
git -C {REPO_ROOT} diff --name-only HEAD
git -C {REPO_ROOT} diff --name-only --cached
```

### 2b. Categorize modified files

Group files based on the repo's architecture (from CLAUDE.md):
- Page/Route files
- Feature components
- Domain logic
- Shared components
- API hooks/services
- Test files
- Config/other

### 2c. Read key modified files

Read the most important modified files to understand WHAT changed. Focus on:
- UI text changes (labels, headings, button text, error messages)
- New interactive elements (buttons, forms, drawers, modals)
- Conditional logic changes (feature flags, permission gates, state checks)
- API call changes (new endpoints, changed parameters)

## 3. Map Files to Routes/URLs

### 3a. Direct route mapping

Use the repo's CLAUDE.md architecture section to understand how files map to routes/screens.
For web apps, map source directories to URL paths.
For mobile apps, map source files to app screens/views.

### 3b. Trace shared component usage

For shared/common files, trace which routes/screens consume them:
```bash
grep -r "ComponentName" {REPO_ROOT}/src/ --include="*.tsx" --include="*.ts" --include="*.swift" -l
```

### 3c. Compile testable surface list

Deduplicate and produce the final list of URLs/screens to test.

## 3-B. Backend Runtime QA (when {QA_SURFACE} = backend)

Unit tests prove the logic; backend QA proves the deployed system exhibits the behavior. The guide has a fixed 5-part shape — deploy confirmation, trigger, data inspection, logs, caveats — because that's what "checking it works" actually means for a service ([[feedback_runtime_evidence_first]]: one log line / one JSON response beats a week of code theories). Everything below generates CONCRETE commands, not advice.

### 3-B.1 Resolve the deploy model

Read `deploy:` from `repo-profiles/{REPO}.yaml` if present. If absent, infer:

```bash
# k8s/Argo service? (documents-api, chat-service, ...)
ls "$WORKSPACE_ROOT"/{gitops-repo}/apps/ | grep -i "{repo-name-variants}"   # {gitops-repo} = your Argo CD GitOps repo
# Lambda repo? (backend-services, mail-service)
[ -d {REPO_ROOT}/lambdas ] && echo "lambda-per-dir, naming {env}-{service}-{lambda}"
```

Store: deploy model (`k8s-argo` | `lambda` | other), Argo app name / lambda naming, namespace (default `dev`). If inference fails, ask the user once and suggest adding a `deploy:` block to the repo profile.

### 3-B.2 Deploy confirmation (merged ≠ deployed — always the first section of the guide)

A merged PR proves nothing until the environment runs it ([[reference_diagnosing_stuck_dev_deploy]]). Generate the check for the resolved model:

**k8s-argo:**
```bash
# what dev is actually running vs what Argo pins
kubectl -n {ns} get pods -l app={argo-app} -o jsonpath='{.items[*].spec.containers[*].image}'
grep newTag "$WORKSPACE_ROOT"/{gitops-repo}/apps/{argo-app}/envs/dev/kustomization.yaml
```
Expected: image tag contains the merge sha. If the pin didn't move, the deploy pipeline (semantic-release tag → argo bump) hasn't run — check the repo's GH Actions run and the Argo app sync state before QA-ing anything.

**lambda:**
```bash
gh run list --repo your-org/{repo} --branch develop --limit 3   # deploy workflow green?
aws lambda get-function --function-name dev-{service}-{lambda} \
  --query 'Configuration.[LastModified,CodeSha256]' --output table
```

### 3-B.3 Trigger the behavior (ordered by proof-strength-per-effort)

Identify how the changed code path is reached, from these classes — read `{REPO_ROOT}/.claude/tickets/PROJ-XXXX-clarify.md` (Dependencies / consumer notes) and `stack-connections.md` for the domain chain:

1. **Consumer surface (prefer when one exists)** — the FE/add-in flow that exercises the change end-to-end. This is the strongest proof because it validates the full chain (service + contract + consumer join keys), and often it's one click. Name the exact user action and the exact visible delta (e.g., "a button that was hidden now appears").
2. **Direct API call** — curl/grpcurl against the dev service (through the BFF with a browser session cookie, or port-forward + OAuth). Check `{REPO_ROOT}/docs/*.postman_collection.json` — if present, name the collection request to use instead of hand-building auth.
3. **Pipeline/event trigger** — when the change sits behind an async flow (Temporal signal, SQS, S3 event): trigger the producing flow and note the expected propagation delay.

**Write-path-only caveat (check EVERY backend ticket for this):** if the change fires only on create/attach/re-process (read the state file's Decisions), say explicitly: *"existing records will NOT show the new behavior — trigger a fresh {X}; old data unchanged is expected, not a bug."* This prevents the classic false-bounce where QA opens an old record and reports failure.

### 3-B.4 Inspect the result (generate assertions, don't say "check the response")

Name where the truth lives and give a runnable assertion:

- **API response JSON** — the usual case. Give the exact fetch (or "DevTools Network tab → {request name}") AND generate a `jq` assertion from the ACs, e.g.:
  ```bash
  jq '{passed: [.redline.twoTierResults.positionAnalyses[] | select(.status=="completed")] | length,
       actions: [.redline.twoTierResults.actions[].id] | length,
       dup_ids: ([.redline.twoTierResults.actions[].id] | length - (unique | length))}' doc.json
  ```
  State the expected numbers/invariants next to it.
- **Database** — only when no API exposes the state: port-forward command from CLAUDE.md + the one SELECT/DDB query.
- **S3 / artifacts** — bucket + key template when the output is a file.

### 3-B.5 Logs / observability (the fallback when 3-B.4 looks wrong)

**Single-service failure** — go straight to the logs:

**k8s:** `kubectl -n {ns} logs deploy/{argo-app} --since=15m | grep -i "{domain terms}"`
**lambda:** `aws logs tail /aws/lambda/dev-{service}-{lambda} --since 15m --filter-pattern "{term}"`

**Multi-component chain (FE/BFF → service → lambda → DB, or producer → queue → consumer) — localize the failing boundary FIRST, before theorizing.** When the behavior crosses ≥2 services, don't guess which one is wrong: in ONE run, capture what data *enters* and *exits* each boundary for the same request/correlation id, then read the sequence to see where it diverges from expected ([[feedback_runtime_evidence_first]]). For each boundary in the chain (from `stack-connections.md` / the clarify Dependencies), grab the log line on BOTH sides:

```bash
# e.g. one flow through FE→BFF→Go lambda, correlated by request id
kubectl -n {ns} logs deploy/{bff-app} --since=15m | grep -i "{reqId}"                    # entered BFF? payload shape?
aws logs tail /aws/lambda/dev-{service}-{lambda} --since 15m --filter-pattern "{reqId}"  # BFF→lambda: arrived? same shape?
# DB / next hop: the one SELECT, or the consumer log for that id
```

Read top-to-bottom: the FIRST boundary where the data is absent, malformed, or shape-shifted (snake_case↔camelCase, dropped field, null vs missing) is the failing layer. Investigate THAT service — not the one showing the symptom — then hand a single, localized bug to §8d / `/project-debug`.

### 3-B.6 Backend guide template

```markdown
# QA Guide: PROJ-XXXX — {summary} (backend)

## Where this runs
- Service: {repo} → {k8s: Argo app {name}, ns dev | Lambda: dev-{service}-{lambda}}
- Exercised by: {trigger class + one-line description}

## 1. Confirm the deploy landed          ← merged ≠ deployed
{model-specific commands + expected tag/sha}

## 2. Trigger the behavior
{consumer-surface click path, or curl/Postman request, or pipeline trigger + delay}
{write-path-only caveat if applicable}

## 3. Inspect the result
{where truth lives + jq/SQL assertion + expected invariants}
- [ ] {AC-derived check 1}
- [ ] {AC-derived check 2}

## 4. If something looks off
{logs command} · then /project-debug (cause-unknown gate)

## Edge cases
- [ ] {error path / idempotency / old-data-unchanged / boundary from the diff}

## Regression checks
- [ ] {sibling behavior that must NOT change — from AC non-goals}

## Pre-merge alternative (optional)
{only if CLAUDE.md documents local run: make compose / port-forwards / sam — with an honest effort note}
```

Then continue at Step 7 (present the guide). Steps 3, 7.5, and 8 do not apply. A failed backend QA step routes through the same §8d cause-unknown gate → `/project-debug`.

## 4. Generate QA Guide

Structure the output based on ticket type:

### For BUGS:

```markdown
# QA Guide: PROJ-XXXX — [ticket summary]

## Environment
- **Dev command:** [from CLAUDE.md, e.g., `yarn dev`]
- **URL:** [from CLAUDE.md, e.g., `https://localhost:3002` — record your dev server in the repo profile]

## URLs/Screens to Test
1. [URL or screen] — [what to look for here]

## Before (Bug Reproduction)
1. [steps to trigger the bug on main branch]
2. **Expected (broken):** [what the bug looks like]

## After (Fix Verification)
1. [same steps on feature branch]
2. **Expected (fixed):** [what correct behavior looks like]

## Edge Cases
- [ ] [edge case 1]

## Regression Checks
- [ ] [related feature that should NOT be broken]
```

### For FEATURES:

```markdown
# QA Guide: PROJ-XXXX — [ticket summary]

## Environment
- **Dev command:** [from CLAUDE.md]
- **URL:** [from CLAUDE.md]

## Acceptance Criteria Verification
### AC1: [text]
1. Navigate to [URL/screen]
2. [steps to verify]
3. **Expected:** [what should be true]
- [ ] Verified

## Edge Cases
- [ ] [edge case]

## Test Data / Accounts
- [what kind of test data or account state is needed]
```

### For IMPROVEMENTS / REFACTORS:
Follow similar patterns, adapted to the ticket type.

## 5. Edge Case Suggestions

Based on the modified code, suggest relevant edge cases:
- **State-related:** empty state, loading state, error state, large data sets
- **Permission-related:** admin vs regular user (check for permission checks in modified files)
- **Input-related:** empty inputs, special characters, very long text
- **UI-related:** drawer/modal open-close cycles, navigation away and back

Only suggest edge cases RELEVANT to the actual code changes.

## 6. Cross-Reference Tests

Check if existing tests cover the affected area:
```bash
ls {REPO_ROOT}/{TEST_DIR}/ 2>/dev/null
```

If relevant tests exist, mention them and suggest running after manual QA.

## 7. Present the QA Guide

Output the complete QA guide. The output must be:
- **Specific** — exact URLs/screens, exact button labels, exact text to look for
- **Actionable** — every item is something the developer can physically verify
- **Concise** — steps, not explanations of code
- **Checkable** — checkboxes for each verification point

## 7.5 UI Preview Harness (for sideload-only flows where Playwright can't drive the real app)

> **First, for any design-fidelity question, hand to the `ui-fidelity` agent (diff mode)** — it produces the per-element contract, the impl gap list (with scoped fixes + shared-component guard), the live-data hardening pass, and the **per-surface manual QA checklist** the human runs in the real app. That is the primary deliverable for sideload visual QA:
> ```
> Task(subagent_type: "ui-fidelity", description: "UI fidelity for {TICKET_ID}",
>   prompt: "ticket_id: {PROJ-XXXX}; repo_root: {REPO_ROOT}; surface: auto; design_reference: {visual-spec.yaml | sibling-surface | screenshots}; impl_files: {modified UI files}; locked_decisions: {from state file}; mode: diff")
> ```
> The static preview harness below is **optional and secondary** — only build it if the user explicitly wants the bounded Playwright geometry screenshots. Per [[feedback_no_preview_screenshot_loop]], do NOT regenerate it each QA round; make the scoped change, lint + component tests, and hand back the agent's manual checklist for in-app QA.

**Why this step exists:** Word Add-in / Google Docs Add-in flows can't be reached via your dev-server URL (e.g. `https://localhost:3002` — see the repo profile) with Playwright because Office.js / Google Apps Script context isn't replicable in a plain browser. The user does in-Word / in-Docs manual QA. But CSS-layout decisions (overlap geometry, narrow-viewport rendering, fixed-position alignment) are the highest-friction class of bugs in those surfaces — pure code review misses them, and the in-Word feedback loop is slow.

The fix: generate a **standalone HTML preview** that inlines the changed CSS Module rules + a minimal DOM mimicking the React JSX, then drive Playwright across viewport widths to screenshot + read computed geometry. This catches gross overlap / alignment issues **before** manual QA, not after.

The preview file is a transient artifact — gitignored, not committed, regenerated on each `/qa` run.

### When to trigger

Auto-trigger this step when **ALL** of these hold:

1. The changeset touches any file under `app/(word-addin)/`, `app/_main/Word-Addin/`, `app/_lib/word-addin/`, OR any other surface flagged in the repo profile's `sideload_only_routes:` list (e.g., Google Docs add-in paths).
2. The changeset includes at least one `*.module.css` change, OR the modified `.tsx` files contain `position: fixed`, `position: sticky`, or layout-affecting structural changes (new wrapper div, flex/grid changes, etc.).

Skip if either condition is missing. For pure logic / data / API changes that don't move pixels, the preview adds no value.

### Step 1: Ask the user before generating

> "UI changeset detected in a sideload-only surface ({affected paths}). I can render a CSS preview at 320 / 400 / 450px (Word Add-in widths) to sanity-check the layout BEFORE you do in-Word QA. Generate? (y/n)"

Don't auto-generate without confirmation — it's an extra step that costs ~30s of Playwright time. The user might prefer to skip if the change is tiny.

### Step 2: Generate the preview HTML

Write to `{REPO_ROOT}/.claude/previews/{TICKET_ID}-{surface-slug}.html` (e.g., `[[PROJ-6296]]-word-addin-bottom-strip.html`).

**Path discipline:**
- `.claude/` is already gitignored in addin-fe (and any repo where it's set up — confirm with `git check-ignore .claude/previews/test.html`). The preview file therefore won't accidentally commit.
- If `.claude/` is NOT gitignored in the target repo, ABORT and tell the user: "preview file would commit accidentally; add `.claude/previews/` to .gitignore before retrying."

**HTML structure:**
- `<!doctype html>` + `<html>` + `<head>` with a `<style>` block.
- The `<style>` block contains the modified `*.module.css` rules from the diff, with the CSS Module class-name hashing stripped — e.g., `.askAiButton { ... }` not `._askAiButton_abc123 { ... }`. Read the raw .module.css files from the working tree and inline them as-is.
- Also include relevant CSS variables — read `app/globals.css` (or equivalent) and inline the `:root { --color-...: ... }` block at the top of the `<style>`.
- Body contains a minimal DOM mirroring the React JSX. Read the relevant `.tsx` file(s) and reconstruct the static markup. **Render multiple sample states** when the JSX has meaningful conditionals — e.g., for [[PROJ-6296]] generate two body sections: one with the chat pill visible (no expanded position) and one with the ExpandedPositionView overlay open (pill hidden).
- Each sample state lives in its own `<div data-preview-state="{name}">` so Playwright can screenshot them independently.

**Mock content:**
- Use realistic text lengths from real fixtures where possible (e.g., the longest action label, the longest section name). Picking artificially short text masks the real overlap risk — this is exactly how the [[PROJ-6296]] 10px-nudge fix shipped without catching the wider "Mark as checked" label.
- For variable-text components, render TWO instances: shortest and longest expected values. The preview's job is to expose the worst case.

### Step 3: Capture each state with headless Chrome, then OPEN it (NOT Playwright)

**Playwright MCP hangs/fails in this environment even for a local `file://`** ([[feedback_no_playwright_live_qa]]) — do NOT use `mcp__playwright__*`. Capture with headless Chrome CLI, which produces a PNG with zero hang.

Screenshots go to the ticket folder `{REPO_ROOT}/.claude/tickets/{TICKET_ID}-screenshots/` ([[feedback_screenshots_to_ticket_folder]]). For each `data-preview-state` div and each viewport width (`[320, 400, 450]` Word Add-in / `[480, 600]` Google Docs sidebar — or the repo profile's `sideload_viewport_widths:`; use a single width like `1000` for a standard web surface):

```bash
DEST="{REPO_ROOT}/.claude/tickets/{TICKET_ID}-screenshots"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || CHROME="$(command -v google-chrome || command -v chromium)"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 \
  --window-size={width},800 --screenshot="$DEST/preview-{state}-{width}.png" \
  "file://{absolute-path-to-preview-html}#{state-name}"
```

**Then OPEN every PNG for the user AND Read it — this is the whole point of the capture, never just print the path** ([[feedback_open_file_command]]):

```bash
open "$DEST"/preview-*.png     # launches Preview so the user actually sees the render
```

Then use the Read tool on each PNG so it renders inline for your own inspection and you can report specifics.

### Step 4: Geometry analysis (visual — Playwright rects unavailable)

Playwright's `getBoundingClientRect()` readback is gone (no MCP here), so inspect the opened/Read PNGs **visually** for the same failure modes: does any flagged element overlap or touch a neighbor (e.g. the priority indicator colliding with the ⋮ menu at a narrow width)? To make overlaps obvious, render the worst-case (longest label / narrowest width) as its own `data-preview-state`.

For each viewport width × state combination, report:
- **PASS:** No two flagged elements overlap.
- **FAIL:** {element A} and {element B} overlap / clip at width {N}px (cite what you see in the PNG).
- **EDGE:** Elements are touching (zero gap) — visually fine but fragile to minor label-width changes.

### Step 5: Present findings

```markdown
## UI Preview Results — `.claude/previews/{TICKET_ID}-{surface-slug}.html`

### Geometry per viewport
| Width | State | Overlaps | Notes |
|-------|-------|----------|-------|
| 320px | pill-visible | ❌ pill (x: 14→164) overlaps Mark-as-checked (x: 85→235) by 79px | wider label exposes the collision |
| 400px | pill-visible | ✅ no overlap | comfortable spacing |
| 450px | pill-visible | ✅ no overlap | |
| any   | overlay-open | ✅ pill hidden via state | conditional render |

### Screenshots (in `.claude/tickets/{TICKET_ID}-screenshots/`, opened in Preview via `open`)
- `preview-pill-visible-320.png`
- `preview-pill-visible-400.png`
- `preview-overlay-open-320.png`
- ...

### Verdict
{If any FAIL at any width:} ⚠ Geometry issues detected at narrow widths. Decide:
  (a) Tighten the CSS (e.g., hide one element via state-driven conditional render — see codebase-patterns "Hide-on-overlap" pattern).
  (b) Accept the overlap at narrow viewports if the user always opens the pane at a wider width (Word default is ~400px+).
  (c) Add a media query that adjusts the layout below the offending breakpoint.

{If all PASS:} ✅ Static geometry is clean at all tested widths. **Still do in-Word QA** — WKWebView has rendering quirks the mock can't reproduce (font metrics, `:has()` support, focus styles).
```

### Step 6: Caveats — what the preview CAN'T do

Mention these every run so the user doesn't over-trust the harness:

- **No React state machine.** Conditional renders are simulated by writing separate states; transitions between them (collapse animations, focus restoration, lazy-mount) aren't tested here.
- **No WKWebView quirks.** `:has()` works in Safari and Chrome but is unreliable in Word's older WebView — flag any `:has()` rule in the preview as "WKWebView-risky" and ask the user to verify in-Word.
- **Font metrics differ.** Word's task pane uses Office's font stack; the preview uses the default browser stack. Text widths can differ by 5-15% — treat width-sensitive geometry as approximate.
- **No Office.js / Intercom SDK.** Intercom launcher position is set by the SDK at runtime; the preview can fake it as a static div at `bottom: 56px; right: 0` but the real launcher height / shadow / hover may differ.
- **Not a replacement for in-Word QA.** This is a pre-flight sanity check. Manual QA still required before merge.

### Path discipline summary

- Preview file: `{REPO_ROOT}/.claude/previews/{TICKET_ID}-{surface-slug}.html` — gitignored, never committed.
- Screenshots: same directory, named `{TICKET_ID}-{state}-{width}.png`. Also gitignored.
- Don't commit either. If the user wants to share a screenshot with PM, they can upload it manually to Jira / Slack.
- On the next `/qa` run for the same ticket, overwrite the existing preview file (don't append, don't version).

## 8. Live QA Execution (Playwright)

> **Disabled in this workspace.** Playwright MCP hangs/fails here even for local files ([[feedback_no_playwright_live_qa]]) — do NOT drive the live app with `mcp__playwright__*`. For a visual artifact, use the Step 7.5 static-preview + headless-Chrome capture, which **always `open`s the resulting PNG** for the user. For behavior/interaction, hand the guide to the user to run on the dev server (e.g. `https://localhost:3002` — record your dev server in the repo profile) and eyeball. Keep §8 below only as reference for environments where Playwright actually works.
>
> **Screenshot rule (applies everywhere in /qa):** any screenshot this command produces is written to `{REPO_ROOT}/.claude/tickets/{TICKET_ID}-screenshots/` and immediately opened with `open <path>` ([[feedback_open_file_command]]) — never just cite the path.

**Skip if** `--guide-only` flag is set, or Playwright MCP is not available, or Chrome debug is not running.

**Check prerequisites:**
Playwright MCP must be available. Dev server must be running on the repo's dev URL (e.g. `https://localhost:3002` — record your dev server in the repo profile).

```bash
curl -s -o /dev/null -w "%{http_code}" {DEV_SERVER_URL} -k 2>/dev/null || echo "Dev server not running"
```

If dev server is not running:
> "Dev server not responding on {DEV_SERVER_URL}. Start it with `yarn dev` first, or type 'skip' for text guide only."

If pages need auth, Playwright will see the login redirect. For auth-protected pages, it will:
1. Try to navigate — if redirected to login, note NEEDS_AUTH
2. Ask user: "This page needs auth. Can you log in via the Playwright browser window, or should I skip live testing for auth pages?"

### 8a. Execute each QA step

For each URL/step in the QA guide:

1. **Navigate** to the URL:
   ```
   mcp__playwright — navigate to {URL}
   ```

2. **Check page loaded** — read the accessibility tree. Look for:
   - Expected headings/titles present
   - No error messages or crash screens
   - Key elements from the AC are visible (buttons, forms, data)

3. **Interact** if the step requires it:
   - Click buttons: `mcp__playwright — click "{button text}"`
   - Fill forms: `mcp__playwright — fill "{field}" with "{value}"`
   - Select dropdowns: `mcp__playwright — select "{option}"`

4. **Verify the expected result:**
   - Check for success messages, updated data, new elements
   - Check for error states that SHOULD appear (e.g., validation errors on empty submit)

5. **Take screenshot** of each step's result:
   ```
   mcp__playwright — screenshot
   ```

6. **Record pass/fail** for each step

### 8b. Edge case testing

For each edge case in the guide:
- Navigate to the page
- Trigger the edge case (empty state, long text, special characters, etc.)
- Check behavior matches expectations
- Screenshot any unexpected behavior

### 8c. Present live results

```markdown
## Live QA Results: PROJ-XXXX

### AC Verification
| AC | URL | Steps | Result | Screenshot |
|----|-----|-------|--------|-----------|
| AC1: [text] | /feature-route/... | Navigate + click | ✅ PASS | [screenshot] |
| AC2: [text] | /feature-route/... | Fill form + submit | ❌ FAIL: form submission returned 500 | [screenshot] |

### Edge Cases
| Case | Result | Notes |
|------|--------|-------|
| Empty state | ✅ PASS | Shows "No items" message |
| Very long text | ⚠️ WARN | Text overflows container | 

### Summary
- Passed: {N}/{total}
- Failed: {N}/{total}
- Warnings: {N}

{If any failures:}
### Failed Steps — Details
1. **AC2**: Form submission returned 500 error. The endpoint `/api/{feature}` may be down or the request payload is malformed. Check the network tab or run `/project-debug` to investigate.
```

### 8d. Failed step → debug session hook

A QA step that fails is a bug whose cause is unknown by definition — you expected it to work. Don't leave it as a red row and move on. For each ❌ FAIL (not ⚠️ WARN), apply the cause-known gate (canonical: `routing.md` → "Bug intake: the cause-known gate"):

> "{N} QA step(s) failed: {one line each}. These have no known root cause yet. Spin a `/project-debug` session to investigate (captures hypotheses + evidence, feeds `/learn`), or are these expected/known? (debug / known)"

On `debug`: create `{REPO_ROOT}/.claude/debug/{slug}.md` seeded from the failing step — symptom = the AC + observed result, reproduction = the QA steps, plus any console/network errors and the failure screenshot path — and set its frontmatter `ticket: PROJ-XXXX`. Then hand to `/project-debug` §4 (spawn the debugger agent if present). This turns a QA bounce into a captured investigation instead of an ad-hoc fix, and the root cause flows back to `/ticket` for the actual change.

On `known`: note it in the report (expected failure / pre-existing / out-of-scope) and don't open a session.

</process>

<success_criteria>
- [ ] Target repo detected
- [ ] Ticket type classified (bug/feature/improvement/refactor)
- [ ] **QA surface auto-detected (1d): ui | backend | mixed — backend tickets get the 3-B runtime-evidence guide, never a URLs/Playwright guide**
- [ ] ACs gathered from state file, Jira MCP, or user input
- [ ] Modified files identified and categorized
- [ ] Files mapped to specific URLs/screens to test (ui) / deploy-model + trigger + assertion resolved (backend)
- [ ] **Backend guides include: deploy confirmation (merged ≠ deployed), trigger with write-path-only caveat, runnable jq/SQL assertion, logs fallback + boundary localization for multi-component chains**
- [ ] Environment and dev commands provided (from CLAUDE.md)
- [ ] QA steps written for each AC
- [ ] Relevant edge cases suggested
- [ ] Output is a practical, actionable QA checklist
- [ ] **UI preview harness offered** (when changeset touches sideload-only surface + CSS / layout)
- [ ] **Preview file lives only at `{REPO_ROOT}/.claude/previews/` — never committed/pushed**
- [ ] **Screenshots captured via headless Chrome CLI (not Playwright) and OPENED with `open <path>`** — every PNG /qa produces is launched in Preview for the user, never just cited as a path
</success_criteria>

## Related Commands
- Context: related-ticket lookup is built into /clarify (Step 1.5)
- Screenshot: /screenshot (capture current state)
- Source: /ticket | /build
- Verify: /verify (automated AC check)
