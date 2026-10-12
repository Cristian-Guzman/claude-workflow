---
name: project-debug
version: 0.8.0
description: Start a systematic debug session with persistent state.
argument-hint: "[issue description]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Write
  - Edit
  - Task
  - AskUserQuestion
---

<objective>
Debug issues using systematic hypothesis testing with persistent state.
Detects the target repo, optionally spawns a debugger agent to keep the main context clean.
</objective>

<process>

## 0. Detect Target Repository

1. **Check current working directory** — if CWD is inside a sub-repo of `$WORKSPACE_ROOT/{repo-name}/`, use that repo. **IMPORTANT:** `$WORKSPACE_ROOT/` itself is NOT a valid target — it's the workspace root. Only match if CWD is at least one level deeper.
2. **Parse $ARGUMENTS** for repo hints
3. **If still ambiguous**, list repos and **always ask the user** using `AskUserQuestion`:
   ```bash
   ls -d $WORKSPACE_ROOT/*/CLAUDE.md 2>/dev/null
   ```

Load repo config:
- Read `{REPO_ROOT}/CLAUDE.md` for conventions and commands
- Check for `{REPO_ROOT}/.claude/codebase-patterns.md` → read if exists
- Check for `{REPO_ROOT}/.claude/agents/debugger.md` → use if exists
- **Cross-repo tracing? `git fetch origin` the sibling repos FIRST** and read via
  `git show origin/<base>:<path>` — a stale checkout produces confident, wrong
  "that logic lives out of workspace" conclusions (PROJ-6601: a 93-commits-behind
  backend-services checkout hid the entire billing layer).

**If `{REPO_ROOT}/CLAUDE.md` does NOT exist**, warn the user:
> "This repo ({REPO_NAME}) doesn't have a CLAUDE.md. I can still debug, but I won't know the project's architecture, conventions, or how to run it. Investigation may take longer."

## 1. Check Active Debug Sessions

```bash
for dir in $WORKSPACE_ROOT/*/; do
  ls "$dir/.claude/debug/"*.md 2>/dev/null
done
```

If active sessions exist AND no $ARGUMENTS:
- List sessions with repo, status, current hypothesis, and next action
- Ask user whether to resume an existing session or start a new one

If $ARGUMENTS provided or user describes a new issue:
- Continue to symptom gathering

## 2. Gather Symptoms (New Issue)

If $ARGUMENTS has enough detail (expected behavior, actual behavior, error messages), skip to Step 3.

Otherwise, use `AskUserQuestion` to gather:

1. **Expected behavior** — What should happen?
2. **Actual behavior** — What happens instead?
3. **Error messages** — Any errors in console, terminal, or browser?
4. **Reproduction steps** — How do you trigger the issue?
5. **Timeline** — When did this start? Was it working before?

## 2.5 API Reference Check (Conditional)

**Only trigger if** the issue mentions API calls, endpoints, 404s, 500s, request/response mismatches, or data not loading.

Check if the endpoint in question exists in the swagger:
```bash
grep -i "relevant-endpoint" $WORKSPACE_ROOT/.claude/api-reference/*.json 2>/dev/null
```

If found: verify the expected request/response shape matches the swagger definition.
If NOT found: the endpoint may not exist, may have been removed, or may need BFF work.

For versioned-API issues, check the version-specific swagger file (e.g. `v2-api.json`) specifically — v1 and v2 APIs may have different endpoint structures.

## 2.6 Live URL Testing (Playwright — if available)

**Only trigger if** the issue involves a URL not working, page not loading, endpoint returning errors, or UI not rendering.

**Sideload-surface gate (check FIRST):** when the debug subject's affected files / diff / state-file paths include ANY of a sideload-only surface's folders — `app/(<surface>)/`, `app/_main/<Surface>/`, `app/_lib/<surface>/` — (or a repo-profile `sideload_only_routes:` path), SKIP this entire section — browser Playwright on the local dev server (e.g. `http://localhost:<port>` — record your dev server in the repo profile) cannot reproduce the bug (Office-detection hooks like `use<Surface>FileInfo` short-circuit to `isIncompatible: true` without Office.js). Emit instead:
> "Word Add-in flow — renders inside Office's task-pane WebView. Open Safari → Develop menu → [your Mac] → [the Word task-pane URL] for DOM/console access (test sideload-only add-in flows in the host app, not the bare dev server)."

If the symptom mentions popover / dropdown / tooltip, also surface the codebase-patterns "Fluent v9 popover won't open" console-probe sequence.

If Playwright MCP tools are available (and the gate above didn't fire):

1. **Navigate to the problem URL:**
   ```
   mcp__playwright — navigate to {dev-server-url}/{problem-path}  # e.g. http://localhost:<port> — record your dev server in the repo profile
   ```
   If the page requires auth, note NEEDS_AUTH and ask the user what they see instead.

2. **Capture what happens:**
   - Does the page load? Read accessibility tree for content.
   - Any error messages visible? Capture them.
   - Console errors? Check for JS exceptions.
   - Blank page? The component might be crashing.

3. **Test related URLs** — if one endpoint is broken, check if similar ones work. This helps isolate whether it's a routing issue, auth issue, or data issue.

4. **Take a screenshot** of the error state for the debug state file.

Add findings to `## Evidence Log` in the debug state file.

If Playwright not available, skip — ask the user to describe what they see in the browser.

## 2.7 Confluence Operational Context (Conditional)

**Only trigger if** the issue description contains operational keywords:
`deploy`, `pipeline`, `CI`, `CD`, `infrastructure`, `AWS`, `Lambda`, `S3`, `production`, `staging`, `build`, `release`, `terraform`, `docker`, `timeout`, `502`, `503`, `500`, `rollback`, `hotfix`, `DNS`, `certificate`, `VPN`, `SSO`, `Jenkins`, `GitHub Actions`

**Skip entirely for code-level bugs** (logic errors, UI issues, type errors, test failures).

**Token budget:** Max 5 search results (titles only), max 1 full page (1500 words). Skip if MCP unavailable.

**Local cache first:**
```bash
grep -i "keyword1\|keyword2" $WORKSPACE_ROOT/specs/confluence/engineering/engineering-index.md 2>/dev/null | head -10
```

**If local cache insufficient**, search Confluence EN space:
```
mcp__atlassian__searchConfluenceUsingCql
  cloudId: "your-org.atlassian.net"
  cql: "type = page AND space.key = EN AND text ~ \"keyword1 keyword2\""
  limit: 5
```

From results:
1. Note page **titles only** — do not fetch full pages
2. If a title is directly relevant (e.g., "Deployment Process", "SSL Certificates Incident"), fetch that one page (max 1500 words)
3. Add findings to the debug state file under `## Confluence Context`

## 3. Create Debug State File

Generate a slug from the issue description (e.g., "data-not-showing-in-table").

Ensure directory exists:
```bash
mkdir -p {REPO_ROOT}/.claude/debug
```

Create `{REPO_ROOT}/.claude/debug/{slug}.md`:

```markdown
---
status: gathering
repo: {REPO_NAME}
ticket: PROJ-XXXX (if applicable)
trigger: "[user's description]"
created: YYYY-MM-DDTHH:MM:SSZ
updated: YYYY-MM-DDTHH:MM:SSZ
---

## Symptoms
- **Expected:** [what should happen]
- **Actual:** [what actually happens]
- **Errors:** [error messages]
- **Reproduction:** [steps to reproduce]
- **Timeline:** [when it started]

## Hypotheses Tested
(none yet)

## Evidence Log
(none yet)

## Fix Attempts
(none yet)

## Current Focus
Starting investigation. Generating initial hypotheses.

## Obsidian Links
- Repo: [[repos/{REPO_NAME}]]
- Related tickets: [[PROJ-XXXX]] (if mentioned in symptoms or $ARGUMENTS; omit line if none)
- Patterns: [[codebase-patterns]] (if `{REPO_ROOT}/.claude/codebase-patterns.md` was loaded)
```

## 4. Spawn Debugger Agent (or debug inline)

**If `{REPO_ROOT}/.claude/agents/debugger.md` exists**, spawn it:

```
Task(
  prompt: "Investigate: {slug}
    Symptoms: {symptoms}
    Repo: {REPO_ROOT}
    Debug state file: {REPO_ROOT}/.claude/debug/{slug}.md
    Follow the debugger agent methodology.
    Update the debug state file as you investigate.
    When done, update status to 'resolved' or 'fixing'.",
  subagent_type: "debugger",
  description: "Debug {slug}"
)
```

**If no debugger agent exists**, investigate inline:
1. Generate hypotheses from symptoms (use the ladder below to seed them)
2. Test each hypothesis systematically
3. Record evidence in the debug state file
4. Continue until root cause found

### 4.1 Visual / UX Bug Hypothesis Ladder

If the symptom contains ANY of these visual keywords — `scroll`, `overflow`, `overlap`, `aligned`, `centered`, `position`, `layout`, `viewport`, `color`, `z-index`, `cut off`, `hidden`, `behind`, `on top of`, `blocking`, `responsive`, `mobile`, `narrow` — seed hypotheses from these 5 categories BEFORE going wider:

#### Category A: Clip-creating ancestors (scroll/overflow bugs)
- Walk the ancestor chain from the suspect element to `<body>`. Flag any with `overflow: hidden|auto|scroll`, `transform`, `filter`, `contain`, `will-change`, `perspective`. ANY of these creates a clipping/containing block boundary.
- **The visibility-pair rule**: `overflow-y: auto` (or scroll/hidden) implicitly computes `overflow-x` to `auto` when not set. So `overflow-y: auto` alone DOES create a horizontal scroll context. Always check both axes are explicitly set on every scroll container.
- Grep heuristic: `grep -rn "overflow:\|overflow-y:\|overflow-x:" {affected_dir}/ --include="*.css" --include="*.module.css"` then trace ancestor-by-ancestor.

#### Category B: Stacking-context ancestry (z-index / overlap bugs)
- `z-index` only compares WITHIN the nearest stacking context. Bumping z-index without finding the context is the classic anti-pattern.
- Walk ancestors looking for: `opacity<1`, `transform`, `filter`, `mix-blend-mode`, `isolation: isolate`, `will-change`, `position: fixed/sticky`. Any of these creates a new stacking context.
- Overlap probe: `document.elementFromPoint(x, y)` at the target's center returns the actual top element. If it's NOT your target, you've found the overlapper without guessing.

#### Category C: Containing-block / positioning bugs
- `position: fixed` inside a `transform`-ed or `filter`-ed ancestor degrades to `position: absolute` against that ancestor. Check BOTH the fixed element AND its ancestors' computed styles.
- Flex chain `height: 100%` breaks if any flex parent lacks `min-height: 0` — child overflow becomes invisible.
- `margin-top` on a scroll container pushes the BOX (invisible below fold); use `padding` so spacing lives INSIDE the scroll viewport.

#### Category D: Narrow-viewport / SDK-quirk bugs
- The Word Add-in pane is ≤450px wide and the Intercom SDK silently ignores `vertical_padding` at that width. **Do not chase the hook value** — use `useNarrowScreen()` + right-padding to make room for the launcher (see codebase-patterns.md → "Intercom: vertical_padding is ignored on screens ≤450px wide").
- Mobile Safari WKWebView has different cursor inheritance, focus, and form-element defaults than Chrome/Firefox.
- Test at 320 / 375 / 414 / 450 / 768 / 1280 px. Many bugs ONLY manifest in narrow viewports.
- Third-party widgets can hijack `<meta name=viewport>` — snapshot before/after and diff.

#### Category E: HMR / build / stale-state bugs
- If a CSS change appears not to render and the file on disk shows the new rule: kill `yarn dev`, restart, re-sideload the add-in. CSS Module HMR can lie.
- Bundler caches at multiple levels (Next.js, the browser, Word's task-pane iframe). When in doubt, hard-restart everything.

### 4.2 Auto-spawn Playwright DOM inspection on visual symptoms

When Playwright MCP is available AND the symptom contains visual keywords (see 4.1 list), automatically run these inspection probes BEFORE forming hypotheses:

```js
// Dump all overflow rules in the suspect subtree
mcp__playwright__browser_evaluate({
  function: `() => {
    const els = [...document.querySelectorAll('*')];
    return els.filter(el => {
      const s = getComputedStyle(el);
      return s.overflow !== 'visible' || s.overflowX !== 'visible' || s.overflowY !== 'visible';
    }).map(el => ({
      selector: el.tagName + (el.id ? '#' + el.id : '') + (el.className ? '.' + String(el.className).split(' ').join('.') : ''),
      overflow: getComputedStyle(el).overflow,
      overflowX: getComputedStyle(el).overflowX,
      overflowY: getComputedStyle(el).overflowY,
      width: el.scrollWidth + 'x' + el.clientWidth,
      height: el.scrollHeight + 'x' + el.clientHeight,
    }));
  }`
})

// Dump all stacking contexts (z-index !== auto)
mcp__playwright__browser_evaluate({
  function: `() => [...document.querySelectorAll('*')]
    .filter(el => getComputedStyle(el).zIndex !== 'auto')
    .map(el => ({
      selector: el.tagName + '.' + String(el.className).split(' ').join('.'),
      zIndex: getComputedStyle(el).zIndex,
      bounds: el.getBoundingClientRect()
    }))`
})

// Overlap probe — what's actually on top at the suspect coordinates?
mcp__playwright__browser_evaluate({
  function: `() => {
    const target = document.querySelector('{suspect_selector}');
    const r = target.getBoundingClientRect();
    return document.elementFromPoint(r.left + r.width/2, r.top + r.height/2)?.outerHTML.slice(0, 200);
  }`
})

// Narrow-viewport sweep — resize and re-check
mcp__playwright__browser_resize({ width: 320, height: 800 })
mcp__playwright__browser_snapshot()
mcp__playwright__browser_resize({ width: 450, height: 800 })
mcp__playwright__browser_snapshot()
mcp__playwright__browser_resize({ width: 1280, height: 800 })
```

Record findings in the debug state file under `## Evidence Log` BEFORE writing hypotheses. The probes often surface the root cause directly.

### 4.3 Parallel agent spawning for visual bugs

If the symptom is visual AND the affected subtree is large (multi-file CSS / multiple components), spawn parallel agents instead of investigating sequentially:

```
Agent 1 (CSS cascade)        — ancestor overflow/transform rules, visibility-pair audit
Agent 2 (DOM structure)      — stacking-context creation, containing-block ancestry
Agent 3 (Viewport / SDK)     — narrow-viewport behavior, Word Add-in vs localhost, third-party widget config
Agent 4 (Build / HMR)        — stale cache, CSS Module HMR state, dev-server restart needs
```

Each agent reports findings into the debug state file's Evidence Log; main thread merges them into hypotheses.

### 4.4 The 3-strike architecture gate

A fix that fails is a new hypothesis, not a retry. Log each fix attempt in the state file's `## Fix Attempts` — one line: what you changed, what you expected, what actually happened.

- **After each failed fix (< 3):** revert it first (test one variable at a time — don't stack a second change on a failed one), then return to Step 4 / the hypothesis ladder with the new evidence.
- **At 3 failed fixes: STOP. Do not attempt fix #4.** Three fixes failing — especially when each one surfaces a new problem in a *different* place, or each real fix would need "massive refactoring" — is the signature of a wrong architecture, not a wrong line. Escalate to the user with the attempt log and one question: *is this pattern fundamentally sound, or are we fixing symptoms of a design that should change?* That's an architectural decision, not another debug loop.

## 5. Handle Results

**If root cause found:**
- Display root cause and evidence summary
- Ask user:
  - "Fix now" — apply the fix in this session
  - "Fix later" — save state for later
  - "Manual fix" — user will fix themselves

**If checkpoint reached (needs human input):**
- Display what's needed from the user
- Save state to debug file
- Get user response and continue

**If inconclusive:**
- Show what was checked and eliminated
- Ask user:
  - "Continue investigating" — provide additional context, continue
  - "Manual investigation" — done for now

</process>

<success_criteria>
- [ ] Target repo detected
- [ ] Active sessions checked (across all repos)
- [ ] Symptoms gathered (if new issue)
- [ ] Debug state file created at `{REPO_ROOT}/.claude/debug/{slug}.md`
- [ ] Debugger agent spawned (if available) or inline debugging performed
- [ ] Root cause confirmed before fixing
- [ ] Debug state file updated with results
</success_criteria>

## Related Commands
- Fix delivery: /pr (after fixing the bug)
- Testing: /test (add regression test)
- If interrupted: /resume-ticket
- Context: related-ticket lookup is built into /clarify (Step 1.5)
- Patterns: codebase-patterns.md
