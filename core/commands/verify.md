---
name: verify
version: 0.4.0
model: "opus[1m]"
description: Goal-backward verification that acceptance criteria are actually met in the code.
argument-hint: "[PROJ-XXXX or paste ACs]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Task
  - Write
  - Edit
  - AskUserQuestion
---

<objective>
Verify that acceptance criteria are actually achieved in the codebase, not just that tasks were completed.
Uses goal-backward methodology: start from what SHOULD be true, verify it IS true.
Includes contract smoke testing to catch frontend/backend boundary mismatches that unit tests miss.
Computes an evidence-backed confidence score (0–100%) for every verification result — arithmetic over receipt-backed gates, never self-reported (see §7).
</objective>

<process>

## 0. Detect Target Repository

1. **Check current working directory** — if CWD is inside a sub-repo of `$WORKSPACE_ROOT/{repo-name}/` (where `$WORKSPACE_ROOT` is your multi-repo workspace root), use that repo. **IMPORTANT:** `$WORKSPACE_ROOT/` itself is NOT a valid target — it's the workspace root. Only match if CWD is at least one level deeper.
2. **Parse $ARGUMENTS** for repo hints or ticket numbers
3. **If still ambiguous**, check which repos have active ticket state files, then **always ask the user** using `AskUserQuestion`:
   ```bash
   for dir in $WORKSPACE_ROOT/*/; do
     ls "$dir/.claude/tickets/"*.md 2>/dev/null
   done
   ```

Load repo config:
- Read `{REPO_ROOT}/CLAUDE.md` for conventions and commands
- Check for `{REPO_ROOT}/.claude/codebase-patterns.md` → if a `codebase-patterns-index.md` exists, read only the "Always Load" core rules section (~250 lines) instead of the full file as the baseline.
  **Then, after Step 2 identifies the modified files, do a second TARGETED pull:** resolve the pattern file's in-file `## Index` and read every entry whose title/anchor matches the modified files' surfaces (path segments, component names, domain terms — e.g. `word-addin`, `api-client`, `playbooks-v2`), plus the 10 newest `## Lessons Learned` entries (tail of the file). The newest lessons are the most likely to be load-bearing for in-flight work, and /learn appends them at the END of the file — a fixed core-rules slice never sees them (this exact blind spot let a documented bug class recur twice in 7 days).
- Check for `{REPO_ROOT}/.claude/agents/verifier.md` → use if exists
- Check for `{REPO_ROOT}/.claude/scripts/capture-screenshot.js` → use for visual verification

**If `{REPO_ROOT}/CLAUDE.md` does NOT exist**, warn the user:
> "This repo ({REPO_NAME}) doesn't have a CLAUDE.md. I won't know which lint, type-check, or test commands to run. I can still verify ACs against code, but quality gates will be skipped."

## 1. Gather Acceptance Criteria

**Option A:** If $ARGUMENTS contains a ticket number, check `{REPO_ROOT}/.claude/tickets/PROJ-XXXX.md` for ACs. If no local state file, fetch via the `jira-context-loader` agent (preferred):

```
Task(
  subagent_type: "jira-context-loader",
  description: "Load ACs for PROJ-XXXX",
  prompt: "Load Jira context for PROJ-XXXX. depth: primary-only. Return the Acceptance Criteria section."
)
```

If the agent isn't available, fall back to direct fetch (try in order):
1. **MCP**: `mcp__atlassian__getJiraIssue` if available
2. **CLI**: `jira issue view PROJ-XXXX --plain` (assumes `jira` is on PATH)
3. **Ask user**: paste ACs manually

**Option B:** If $ARGUMENTS contains ACs directly, use those.

**Option C:** If no $ARGUMENTS, check for active ticket state files in the detected repo. Use the most recently updated active ticket.

## 2. Identify Modified Files

Resolve the base branch via repo profile (NEVER hardcode `main`):

```bash
REPO_NAME=$(basename {REPO_ROOT})
PROFILE=$WORKSPACE_ROOT/.claude/repo-profiles/${REPO_NAME}.yaml
if [ -f "$PROFILE" ]; then
  BASE_BRANCH=$(grep '^base_branch:' "$PROFILE" | awk '{print $2}' | tr -d '"')
else
  BASE_BRANCH=$(grep -oE 'base-branch:\s*\S+' {REPO_ROOT}/CLAUDE.md 2>/dev/null | awk '{print $2}')
  : "${BASE_BRANCH:=main}"
fi
```

If no profile exists, warn: "No repo profile for $REPO_NAME — using fallback $BASE_BRANCH. Create `.claude/repo-profiles/${REPO_NAME}.yaml` to silence this."

Use `$BASE_BRANCH` here and everywhere a diff is needed.

```bash
git -C {REPO_ROOT} diff --name-only {BASE_BRANCH}...HEAD
```

**Branch base sanity check:** distinguish *wrong-based* from merely *behind* — a bare `is-ancestor` test fails for ANY branch that's behind the tip (the common mid-sprint case) and produced false-positive WRONG_BASE blockers:
```bash
mb=$(git -C {REPO_ROOT} merge-base origin/{BASE_BRANCH} HEAD 2>/dev/null)
if [ -z "$mb" ]; then
  echo "WRONG_BASE — no common ancestor with origin/{BASE_BRANCH}"
elif git -C {REPO_ROOT} merge-base --is-ancestor "$mb" "origin/{BASE_BRANCH}" 2>/dev/null; then
  behind=$(git -C {REPO_ROOT} rev-list --count HEAD..origin/{BASE_BRANCH})
  ahead=$(git -C {REPO_ROOT} rev-list --count origin/{BASE_BRANCH}..HEAD)
  echo "OK — $ahead ahead, $behind behind origin/{BASE_BRANCH}"
  [ "$behind" -gt 5 ] && echo "  ⚠ stale: consider rebasing before /pr"
else
  echo "WRONG_BASE — common ancestor not on origin/{BASE_BRANCH}"
fi
```
Only true WRONG_BASE is a blocker:
> "⚠️ This branch is NOT based on `{BASE_BRANCH}`. For repos whose profile records a non-default base branch (e.g. api-bff and web-app, which base on `develop-v2`), merging to the wrong base has already caused production issues. Rebase onto `{BASE_BRANCH}` before proceeding."

Behind-but-correctly-based is a soft warning, never a blocker.

## 2.1 Tests-For-Every-Source Enforcement

For every modified source file, check that a corresponding test file exists:

```bash
# Example for TS/TSX frontend:
for src in $(git -C {REPO_ROOT} diff --name-only {BASE_BRANCH}...HEAD | grep -E '\.(ts|tsx)$' | grep -v '\.test\.\|__tests__\|\.d\.ts$'); do
  base=$(basename "$src" | sed -E 's/\.(ts|tsx)$//')
  if ! find {REPO_ROOT}/__tests__ -name "${base}.test.*" 2>/dev/null | grep -q .; then
    echo "MISSING TEST: $src"
  fi
done
```

If any source file has no matching test, **BLOCK** with:
> "⚠️ {N} modified source file(s) have no matching tests. Per user policy (always add tests), do not mark verification DONE until tests are added. Run `/test` to generate them, or confirm these files genuinely need no test (e.g., pure types, config)."

Allow the user to override with an explicit "no test needed because {reason}" — record the reason in the event log.

## 2.2 Surface Relevant Command Proposals

If `.claude/command-proposals.md` exists at the workspace root or repo root, grep for proposals matching current work:

```bash
# Check workspace-root proposals
grep -B 1 -A 5 -i "$(echo $REPO_NAME | head -1)" $WORKSPACE_ROOT/.claude/command-proposals.md 2>/dev/null
# Check modified-file patterns against proposal descriptions
for f in $(git -C {REPO_ROOT} diff --name-only {BASE_BRANCH}...HEAD); do
  grep -l "$(basename $f)" $WORKSPACE_ROOT/.claude/command-proposals.md 2>/dev/null
done
```

If any proposal matches, surface it:
> "Heads up: a known pattern issue is tracked in command-proposals.md that may apply here:
> {excerpt}
> Keep in mind while verifying."

This is informational — do NOT block on it.

## 2.5 Reflexion — Self-Critique Before Verification

Before checking ACs, do a quick self-assessment of the implementation. Read the modified files and ask:

1. **What am I NOT confident about?** — Which parts of the implementation feel fragile, rushed, or unclear?
2. **What could break?** — Edge cases not covered, error states not handled, race conditions possible?
3. **What did I assume without verifying?** — API response shapes, component props, state management behavior?
4. **What's missing?** — Tests not written, loading states not handled, accessibility not considered?

Present a brief reflexion summary:
```
## Reflexion (Pre-Verification Self-Critique)
- Confidence gaps: {list anything uncertain}
- Potential breakpoints: {edge cases or fragile code}
- Unchecked assumptions: {things assumed but not verified}
- Missing pieces: {tests, states, or behaviors not implemented}
```

This step catches issues BEFORE the formal AC check — it's faster to fix something you already know is wrong than to discover it through verification.

If reflexion reveals critical gaps, ask the user:
> "I found {N} concerns before even checking ACs. Want to fix these first, or proceed with verification?"

## 2.6 Battery Selection (Tier-Aware)

Classify the ticket on three independent axes, then run only the checks that apply. Output a `battery` array consumed by Steps 3, 5, 6, and 7.

### Axes

**HAS-UI?** yes if any of:
- `tags.layer == "ui"` OR `tags.atomic_level ∈ {atom, molecule, organism, template, page}`
- any modified file matches `*.tsx | *.module.css | globals.css | app/(web)/ | app/(word-addin)/ | app/_common/ | app/_lib/**/components/`
- AC text matches `/\b(render|click|button|page|view|column|section|hover|focus|tab|modal|drawer|tooltip|badge|pill|chip|accordion|dropdown|menu|card|banner|skeleton|breadcrumb|toast|chevron|icon|panel|sidebar|header|footer|layout|placeholder|input|toggle|form|field|displayed|appears|shown|visible|hidden|collapsed|expanded)\b/i`

**HAS-WIRING?** yes if any of:
- `tags.layer ∈ {bff, api, data}`
- any modified file matches `app/_api-client/ | app/_entities/ | src/routes/ | lambdas/ | *.go`
- any modified file contains `useQuery | useMutation | fetch( | axios.`
- AC text matches `/\b(fetch|load|save|submit|API|endpoint|mutation|create|update|delete|persist|invalidate|sync|optimistic|auto-?save|cache|query|hook)\b/i`
- Plan Summary mentions `selector | mapper | query hook | mutation hook | BFF | cache invalidation`

**HAS-VISUAL-SPEC?** (prerequisite: HAS-UI must be true)
- S1: `## Classification` mentions `/Design case:\s*(Prototype reference|Figma|design screenshot|mockup|screenshot)/i`
- S2: `## Plan Summary` / `## Decisions Made` mentions `/Figma|mockup|design (screenshot|spec)|prototype reference|proto\/[\w-]+/i`
- S3: `## Files Modified` contains `globals.css` OR ≥2 `*.module.css` files
- S4: AC text matches color/visual lexicon `/\b(blue|red|green|yellow|orange|purple|amber|gray|grey|color|background|border|outline|shadow|rounded|underline|strikethrough|highlight|bold|italic|tint|accent|gradient|chevron|icon|svg)\b/i`
- S5: AC text matches visual-comparison verbs `/\b(matches?|consistent with|aligned? with|as (in|per) (the )?(design|prototype|mockup|Figma|screenshot|image|spec))\b/i`
- S6: `atomic_level ∈ {organism, template, page}` AND Plan mentions new CSS tokens / animations / keyframes / hover-focus / "indicator"
- S7: AC text matches `/\b(badge|pill|chip|banner|skeleton|chevron|connector line|indicator|tracked changes? (display|view))\b/i`
- S8: AC text matches layout vocab `/\b(layout|whitespace|padding|margin|spacing|indentation|positioned?|placed?|order|above|below|next to|between|inside|outside)\b/i`
- S9: AC text mentions `/\b(inline (edit|editing)|chip input|toggle|placeholder|hover state|focus state)\b/i`

(Validated against 20 real addin-fe tickets: 0% false-negative on HAS-VISUAL-SPEC after S3/S8/S9 refinements. Sample skews UI-heavy so real-world FN rate likely 5-15%.)

### Battery composition

```
battery = []
if HAS_UI:             battery += [render_check, a11y_smoke, css_token_compliance, viewport_sweep]
if HAS_WIRING:         battery += [contract_check, query_hook_invocation, mutation_invalidation]
if HAS_VISUAL_SPEC:    battery += [visual_compare]   # runs BOTH static + runtime (Playwright getComputedStyle)
if not HAS_UI and not HAS_WIRING:  battery += [targeted_unit_test_only]
```

When `HAS_UI=true` AND the file list includes anything under `app/_lib/word-addin/` OR `app/(word-addin)/`, force `viewport_sweep` to include the `320x800` viewport (Word Add-in pane width). When `HAS_UI=true` AND a Figma link or Visual/CSS claim was extracted in `/clarify` Step 2, force `visual_compare` to RUN (do not skip even if visual-spec.yaml was missing — emit `NOT_RUN_STATIC` so the report flags it).

**Sideload-only surfaces:** when every UI-modified file sits under `app/(word-addin)/`, `app/_main/Word-Addin/`, `app/_lib/word-addin/`, or a path in the repo profile's `sideload_only_routes:` list, browser Playwright cannot drive the real surface (Office.js task-pane WebView) — emit `viewport_sweep = NOT_RUN_EXPECTED` (skip the runtime probes silently; in-Word manual QA is the substitute). This is reported, never clamped — MEDIUM-when-actually-HIGH on every Word Add-in ticket erodes trust in all the other clamps.

### Named battery: mechanical-removal tickets

When the state file's `## Classification` says cleanup/removal (mechanical-lean), use the 3-lens removal battery instead of the generic checks (validated on [[PROJ-6316]] + [[PROJ-6318]]: 12 confirmed real findings, 0 false blockers):
1. One agent **per deletion block** — completeness + behavior-equivalence proof (nothing the deleted code did survives unowned)
2. One agent **simulating the CI gate with sentinel injection** — would CI actually catch a partial removal?
3. One adversarial agent restricted to **doc/comment/script drift** — Standards/, CLAUDE.md, embedded JSON headers, `*.sh` greps over changed files

Per [[feedback_lean_workflow_mechanical_phases]], do NOT add per-file adversarial review beyond these three lenses — build + grep IS the verification for mechanical phases.

### `visual_compare` check

> **Sideload / cross-framework surface → delegate to the `ui-fidelity` agent (diff mode).** The static-CSS + Playwright-runtime checks below assume `*.module.css` and a browser-drivable page. They emit `NOT_RUN` for Tailwind/MUI + sideload surfaces (Word add-in, GDocs add-in, iOS) — exactly where fidelity bugs hide. For those, invoke the agent instead; use its gap table + manual-QA checklist as this check's result, and apply the §7 clamps to its findings:
> ```
> Task(subagent_type: "ui-fidelity", description: "UI fidelity for {TICKET_ID}",
>   prompt: "ticket_id: {PROJ-XXXX}; repo_root: {REPO_ROOT}; surface: auto; design_reference: {visual-spec.yaml | sibling-surface | screenshots}; impl_files: {modified UI files}; locked_decisions: {from state file Decisions Made}; mode: diff")
> ```
> The agent ALWAYS runs the live-data hardening pass ([[feedback_design_fidelity_live_data]]) — treat an unhandled live-data shape (unclamped overflow, missing empty-state) as a `GAPS_FOUND` finding even when the mock-match is clean. Manual-QA-checklist hand-off replaces runtime readback on sideload surfaces (no clamp — it's structurally impossible, like `viewport_sweep = NOT_RUN_EXPECTED`).

When `HAS_VISUAL_SPEC` is true, load `{REPO_ROOT}/.claude/tickets/PROJ-XXXX-visual-spec.yaml` (produced by `/clarify` Step 2.5b). Run BOTH a static comparison (CSS Module grep) AND, when the dev server is running, a runtime comparison via Playwright `getComputedStyle()` readback. The runtime check catches CSS-cascade and visibility-pair bugs the static grep cannot see.

#### Phase A — Static comparison (always runs)

```python
for component in spec.components:
    impl_css = read_module_css(component.impl_target)
    for state, properties in component.states.items():
        for prop, expected in properties.items():
            actual = grep_property(impl_css, prop, state_selector(component, state))
            if actual is None:
                gaps.append((component.name, state, prop, "MISSING"))
            elif normalize(actual) != normalize(expected):
                gaps.append((component.name, state, prop, f"mismatch: got {actual}, expected {expected}"))
    if component.header.right_icon:
        impl_tsx = read_component_tsx(component.impl_target)
        if not has_icon(impl_tsx, component.header.right_icon):
            gaps.append((component.name, "header.right_icon", "MISSING"))
```

#### Phase B — Runtime comparison via Playwright (when dev server is up)

When `curl -s -o /dev/null -w "%{http_code}" {dev_server_url} -k` (e.g. `https://localhost:3002` — record your dev server URL in the repo profile) returns 2xx/3xx AND `mcp__playwright` tools are available, navigate to the feature URL and readback computed styles for each spec component. This catches:

- CSS-cascade bugs where the static grep sees the rule but a higher-specificity selector overrides at runtime
- Visibility-pair gotchas (`overflow-y: auto` implicitly setting `overflow-x: auto`)
- Token resolution drift (CSS variable points to a different hex than the spec assumed)
- Stacking-context bugs (z-index doesn't behave as written because an ancestor created a new stacking context)

```js
// Pseudocode — for each component in the visual-spec.yaml:
mcp__playwright__browser_navigate({ url: feature_url })

for (const component of spec.components) {
  // Locate the element via data-testid (spec must declare one)
  const computed = await mcp__playwright__browser_evaluate({
    function: `() => {
      const el = document.querySelector('[data-testid="${component.testid}"]');
      if (!el) return { missing: true };
      const s = getComputedStyle(el);
      return {
        // Layout
        display: s.display, justifyContent: s.justifyContent, alignItems: s.alignItems,
        // Box
        padding: s.padding, margin: s.margin, borderRadius: s.borderRadius, border: s.border,
        // Visual
        backgroundColor: s.backgroundColor, color: s.color, opacity: s.opacity,
        // Position / scroll
        position: s.position, overflow: s.overflow, overflowX: s.overflowX, overflowY: s.overflowY,
        zIndex: s.zIndex, transform: s.transform,
        // Box model
        rect: el.getBoundingClientRect(),
      };
    }`
  });

  // Compare against spec.components[i].states.default
  for (const [prop, expected] of Object.entries(component.states.default)) {
    if (normalize(computed[prop]) !== normalize(expected)) {
      runtimeGaps.push({ component: component.name, state: 'default', prop, expected, actual: computed[prop], source: 'runtime' });
    }
  }
}
```

For interactive states (hover, focus-visible, active, disabled), use `mcp__playwright__browser_hover`, focus events, or `setAttribute('disabled', '')` and re-evaluate. For loading states, mock the relevant query in setup.

**Result codes:**
- `OK` — no gaps in either phase
- `GAPS_FOUND` — at least one missing or mismatched property in EITHER phase
- `RUNTIME_OK_STATIC_GAPS` — static grep found gaps but runtime readback is correct (likely cascade override; investigate but not blocking)
- `STATIC_OK_RUNTIME_GAPS` — static grep clean but runtime differs (cascade or specificity override; HIGH PRIORITY — this is exactly the class of bug code-only verification misses)
- `DEFERRED_TO_MANUAL` — spec has `manual_review_required: true` (Figma-only tickets)
- `NOT_RUN_STATIC` — `HAS_VISUAL_SPEC=true` but spec file does not exist on disk
- `NOT_RUN_RUNTIME` — dev server unreachable or Playwright MCP unavailable; static-only result reported

### `viewport_sweep` check (NEW — bundled with visual_compare when HAS_UI=true)

For tickets where `HAS_UI=true`, after the default-viewport runtime check, resize the browser to `320x800`, `450x800`, and `1280x800` and re-evaluate the computed styles for each visual-spec component. Catches:

- Narrow-viewport SDK quirks (e.g., Intercom ignoring `vertical_padding` ≤450px — the bug pattern from [[PROJ-6088]]/6089)
- Responsive breakpoint bugs where a media query fires at the wrong width
- Word Add-in pane behavior (always ≤450px) that desktop browser at 1280px never reproduces

```js
for (const width of [320, 450, 1280]) {
  await mcp__playwright__browser_resize({ width, height: 800 });
  await mcp__playwright__browser_snapshot();

  // For each component, capture computed styles + bounding box
  // Compare bounding boxes across viewports — does the element disappear, overlap, or get clipped?
  // For Word Add-in flows specifically, the 320 and 450 readings are the source of truth (NOT 1280).
}
```

**Result codes:**
- `OK` — all viewports render the spec consistently
- `BREAKPOINT_DRIFT` — element bounding box or computed style changes unexpectedly across viewports (vs the spec's `narrow_viewport` declarations)
- `NARROW_VIEWPORT_BUG` — narrow viewport renders differently than spec AND the component is in `app/_lib/word-addin/` (this MUST block PR; the Word Add-in pane is always narrow)
- `NOT_RUN` — Playwright unavailable
- `NOT_RUN_EXPECTED` — sideload-only surface (see §2.6): the runtime probe is structurally impossible, in-Word QA is the substitute. No clamp; gets its own report row.

### `css_token_compliance` check (formalization)

For each `*.module.css` file in the modified-files list, parse and flag:

1. **Hardcoded hex / rgb / rgba values** in property values (except inside `var(--token, fallback)` where the fallback is permitted)
2. **Non-token color names** (`orange`, `red`, `white`) outside of `var()` fallbacks
3. **Magic numbers for spacing** when the existing globals.css defines a spacing scale

Grep heuristic:
```bash
# Find hardcoded colors in modified CSS Modules
grep -rnE "(background-color|color|border-color):\s*(#|rgb|rgba|[a-z]+\s*;)" \
  {modified_module_css_files} | grep -v "var(--"
```

Result codes:
- `OK` — every color/spacing value uses a token reference
- `HARDCODED_VALUES_FOUND` — cap the score at 85% unless the user explicitly approved hardcoding (e.g., via PR comment or ticket decision)

### State file event log

```
- [verify-classify HH:MM] HAS_UI={...} HAS_WIRING={...} HAS_VISUAL_SPEC={...} battery=[...]
- [visual_compare HH:MM] {N} gaps found across {M} components
```

Output gap table inline in the verification report:

```markdown
## Visual Spec Gaps

| Component | State / Element | Property | Expected | Actual | Status |
|---|---|---|---|---|---|
| InDepthAnalysis | collapsed | background-color | rgba(147,197,253,0.5) | (none) | ❌ MISSING |
| InDepthAnalysis | header.right_icon | faMicroscope | (none) | ❌ MISSING |
```

## 3. Run Verification

### 3.0 Verification mode (single-pass vs multi-agent)

Default = one verifier pass. **Auto-escalate to the 5-agent battery** — AC verifier, contract verifier, repo-integrity (one per repo), security/quality — when ANY of:
- `## Files Modified` has **≥ 7 entries**
- the state file has `sibling-repo:` frontmatter (cross-repo work)
- the event log spans **≥ 2 distinct sessions** (compaction or day breaks)

Evidence: single-pass on [[PROJ-6214]] (16 files, 2 repos, 4 sessions) reported MEDIUM while missing four issue classes — broken test mocks, 3 contract drifts, dead code, missing QueryClientProvider wrappers — that the 5-agent pass caught in minutes; recurred on [[PROJ-6394]] (5-lens pass caught a MAJOR seam-coverage gap the single pass missed). Override with `--single-pass`. **Exception:** mechanical-removal tickets use the §2.6 removal battery instead — lean, not wide ([[feedback_lean_workflow_mechanical_phases]]).

### Mocks-first deferrals are NOT violations

Before flagging any AC as FAILED, read the state file's `## Decisions Made`. If a decision defers that AC's wiring — keywords: "mocks-first", "backend dependency", "blocked by [[PROJ-X]]", "deferred to [[PROJ-X]]", "spec wording predates" — report the AC as **`PARTIAL — by-design pending [[PROJ-X]]`**, citing the deciding entry. Do NOT cap the score for a consciously deferred sub-requirement ([[feedback_no_speculative_plumbing_warnings]]; the [[PROJ-6240]] false "AC6 violation" cost a re-framing round-trip).

**If `{REPO_ROOT}/.claude/agents/verifier.md` exists**, spawn the verifier agent:

```
Task(
  description: "Verify ACs against codebase",
  subagent_type: "verifier",
  prompt: "Verify these acceptance criteria against the codebase:

    ACs: {acceptance_criteria}
    Modified files: {file_list}
    Ticket: {PROJ-XXXX}
    Repo: {REPO_ROOT}

    Follow the verifier agent methodology.",
  subagent_type: "verifier",
  description: "Verify PROJ-XXXX ACs"
)
```

**If no verifier agent exists**, do inline verification:

For EACH acceptance criterion:
1. What must be TRUE for this AC to be met?
2. Which file(s) implement this truth?
3. Is the code real? (not stub, placeholder, TODO, empty handler)
4. Is the code wired? (imported, used, rendered — not orphaned)

### 3.1 Substance Checks (Anti-False-Positive)

Beyond "file exists," verify real implementation:

1. **Files have substance** — a component file with just an empty export, a TODO, or `return null` doesn't count. Check that exported functions/components have real implementations (>5 lines of logic, not stubs).

2. **FILE MAP compliance** — if the ticket has a FILE MAP section:
   - Every file marked CREATE must exist
   - Every file marked MODIFY must appear in `git diff --name-only`
   - Flag any FILE MAP entries that don't match reality

3. **TEST SPECIFICATION compliance** — if the ticket has a TEST SPECIFICATION section:
   - Every P0 test case must have a corresponding test file
   - The test file must actually run (`yarn test {file} --run` exits 0)
   - Flag any P0 test cases without implementations

4. **E2E test compliance** — if the ticket's test spec lists E2E tests:
   - Check if the E2E test files exist at the specified paths
   - If they don't exist, flag: "E2E tests specified but not implemented"
   - Do NOT mark DONE if E2E tests are listed but missing

5. **Handler completeness** — for interactive elements (buttons, menu items, form actions):
   - Check that onClick/onSubmit handlers are wired (not empty `() => {}` or TODO)
   - Check that mutation hooks are called in handlers, not just imported

6. **Type-duplication scan** — for every `export (interface|type) {Name}` ADDED in the diff:
   ```bash
   grep -rEn "^export (interface|type) {Name}\b" {REPO_ROOT}/app/_entities/ {REPO_ROOT}/app/_api-client/ 2>/dev/null | grep -v "{this_file}"
   ```
   A match in `app/_entities/` (the canonical layer) is **BLOCKING** — reuse via import or consolidate (codebase-patterns "Use existing types"); a match elsewhere is a non-blocking finding. Second line of defense after `/clarify` §4e: same grep, different gate ([[PROJ-6082]] shipped ~70 lines of shadow types through a HIGH-confidence verify).

7. **MOCK_LEAK scan** (deterministic) — changed api-client files must not statically import fixtures, and public barrels must not re-export them (mock data loads via dynamic `import()` only):
   ```bash
   git -C {REPO_ROOT} diff --name-only {BASE_BRANCH}...HEAD | grep -E 'api-client.*\.ts$' \
     | xargs -I{} grep -nE '^import .*from .*"\./(test-fixtures|mocks)"' {REPO_ROOT}/{} 2>/dev/null
   git -C {REPO_ROOT} diff --name-only {BASE_BRANCH}...HEAD | grep -E '_api-client/.*/index\.ts$' \
     | xargs -I{} grep -nE 'export .*from .*"\./(test-fixtures|mocks)"' {REPO_ROOT}/{} 2>/dev/null
   ```
   Any match → flag **MOCK_LEAK** with a pointer to the codebase-patterns entry. This rule is documented but the agent catching it was non-deterministic — this grep makes it deterministic.

### 3.2 Quality Gates

Run quality gates using commands from CLAUDE.md:
- Linting command
- Type checking command — **resolve what CI ACTUALLY gates on first**: read the `ci` script in package.json (addin-fe and web-app gate on `type-check:ci` / `tsconfig.ci.json`, NOT bare `tsc --noEmit`). If the repo has both, run both and report divergence: `default tsc: ✓ | CI tsconfig: ✗ — {N} errors in CI-only check`. Never assert "CI will pass/fail" from a command CI doesn't run — both failure directions have happened ([[PROJ-6240]]: local tsc green, CI tsconfig red; [[PROJ-6394]]: agent declared CI-red from FULL tsc output that CI never runs)
- Test command for modified files
- **GAS build-contract check** (only repos with `scripts/build-server.mjs`, i.e. gdocs-addin): extract every `runServer<...>('handleX'` callsite from `src/client/**`, then set-diff against `GLOBAL_FUNCTIONS` in `scripts/build-server.mjs` AND `HANDLER_MAP` in `src/client/utils/devHandlers.ts`. A handler missing from either is a deploy-time dead call that CI cannot see (integration tests mock `google.script.run`) — this exact class shipped twice in 7 days (PR #169, #179) before this check existed. Missing registration = BLOCKING.
- **GAS event-allowlist check** (same repos): every event name passed to `captureChatSuggestionEvent` in `src/client/**` must appear in `ALLOWED_CHAT_EVENT_NAMES` in `src/server/Code.ts`, else the server rejects it and the fire-and-forget client swallows the error (silently-dropped analytics). Same shape as the GAS build-contract check. An emitted-but-unallowlisted event = BLOCKING:
  ```bash
  grep -rhoE "captureChatSuggestionEvent\('[a-z0-9._]+'" src/client/ | grep -oE "'[a-z0-9._]+'" | tr -d "'" | sort -u > /tmp/emitted-events.txt
  awk '/ALLOWED_CHAT_EVENT_NAMES/,/\]\)/' src/server/Code.ts | grep -oE "'[a-z0-9._]+'" | tr -d "'" | sort -u > /tmp/allowed-events.txt
  comm -23 /tmp/emitted-events.txt /tmp/allowed-events.txt   # emitted but NOT allowlisted → silently dropped
  ```
  Prose alone didn't prevent this (`chat_opened` shipped unallowlisted in [[PROJ-6627]]); this is the compiled check. Some legacy event families may be known-drifted — record them in the repo profile.

If `codebase-patterns.md` was loaded, also check modified files for convention violations:
- Scan for patterns the file explicitly forbids (e.g., hardcoded colors, `any` types, native inputs)
- Report any violations found alongside the AC verification results

### 3.2b E2E Execution Gate (when modified files touch `e2e/**`)

`yarn ci` does NOT run Playwright (it's lint + type-check + Vitest only), and E2E gates no PR — it runs nightly against deployed dev. So an E2E-touching ticket can pass every PR check while its specs are broken or flaky. When the diff includes `e2e/**`:

1. **`networkidle` ban (mechanical):** changed e2e files must not introduce the discouraged anti-pattern (see testing-patterns "Never use waitForLoadState(\"networkidle\")"):
   ```bash
   git diff --name-only $(git merge-base origin/develop HEAD)..HEAD -- 'e2e/**' \
     | xargs grep -nE 'waitForLoadState\("networkidle"\)' 2>/dev/null
   ```
   Any hit → cap the score at 85%, reason "reintroduces discouraged `networkidle`; replace with a web-first wait."
2. **Run the touched specs against the BRANCH, not the old deploy** (frontend repos; creds in `.env`). The config's default baseURL is DEPLOYED dev — pre-merge it still serves the code *without* this branch, so a touched spec asserting new behavior can only fail there ([[PROJ-6522]] was flagged-not-run for exactly this). Target the local dev server instead (canonical: testing-patterns "## E2E repo-awareness, blast-radius & skip contract" §2b):
   ```bash
   LOCAL=$(grep -A60 '^e2e:' "$PROFILE" | grep 'local_base_url:' | awk '{print $2}' | tr -d '"')   # fallback below is an example — record e2e.local_base_url in the repo profile
   curl -sk -o /dev/null -w "%{http_code}" "${LOCAL:-https://localhost:3002}" --max-time 3   # 2xx/3xx = branch is being served
   PLAYWRIGHT_BASE_URL="${LOCAL:-https://localhost:3002}" yarn test:e2e {changed e2e spec paths} --workers=1 --reporter=line
   ```
   Auth is domain-scoped — never `REUSE_AUTH=true` across targets; the setup project re-logs-in from `.env` creds (§2b gotchas). If the local server is DOWN, ask the user to start `yarn dev` or record the specs as flagged for the post-deploy re-check (§3.2c Step 5) — never silently fall back to deployed dev pre-merge.
   Record pass/fail in the report. A genuine failure that survives the config's retries → do NOT report HIGH; name the failing test. Pre-existing rot in UNCHANGED specs is non-blocking ([[feedback_e2e_rot_not_blocking]]) — note it, don't clamp. Run low-concurrency (`--workers=1`) so you measure correctness, not self-induced load flake.

### 3.2c E2E-Drift Detection (app-side, repo-aware)

§3.2b only fires when the diff touches the spec dir itself. But the worse failure mode is the reverse: an **app-side** change (a route rename, a copy string, a `data-testid`, a GET→SSE migration) that no spec file in the diff reveals, yet silently breaks specs that assert the old surface. Those breaks never gate a PR (E2E runs nightly against deployed dev), so they ship as drift and surface as red the next morning — or worse, get masked by a `test.skip` / `isVisible().catch(()=>false)` guard and never go red at all (false-green). This step catches that drift at verify time.

**Step 1 — Gate on repo e2e-awareness (skip silently if absent).** Resolve `e2e.enabled` exactly as defined in the canonical reference — addin-fe testing-patterns **"## E2E repo-awareness, blast-radius & skip contract"** (read the repo profile's `e2e:` block; if the profile is silent, auto-detect a `playwright.config(.ts|.js)` + a `test:e2e` script + a spec dir). If not e2e-enabled → **skip this entire step with no output** (no friction for web-app/api-bff, backend-service repos, iOS, legacy-editor, infra repos, etc.). Always read `spec_dir`, `run_command`, `config`, and `sideload_only` from the resolved profile — **never hardcode `e2e/`** (GDocs uses `test/e2e/`).

```bash
REPO_NAME=$(basename {REPO_ROOT})
PROFILE=$WORKSPACE_ROOT/.claude/repo-profiles/${REPO_NAME}.yaml
E2E_ENABLED=$(grep -A1 '^e2e:' "$PROFILE" 2>/dev/null | grep 'enabled:' | awk '{print $2}')
if [ "$E2E_ENABLED" != "true" ]; then
  # auto-detect fallback (profile silent): need config + test:e2e script + a spec dir
  { [ -f {REPO_ROOT}/playwright.config.ts ] || [ -f {REPO_ROOT}/playwright.config.js ]; } \
    && grep -q '"test:e2e"' {REPO_ROOT}/package.json 2>/dev/null \
    || exit 0   # not e2e-enabled → silent no-op
fi
SPEC_DIR=$(grep -A6 '^e2e:' "$PROFILE" 2>/dev/null | grep 'spec_dir:' | awk '{print $2}' | tr -d '"'); : "${SPEC_DIR:=e2e/}"
SIDELOAD=$(grep -A6 '^e2e:' "$PROFILE" 2>/dev/null | grep 'sideload_only:' | awk '{print $2}')
RUN_CMD=$(grep -A6 '^e2e:' "$PROFILE" 2>/dev/null | grep 'run_command:' | sed -E 's/.*run_command:\s*//' | tr -d '"')
```

**Step 2 — Fire only when the diff changes APP surfaces (not just specs).** If the diff is spec-only, §3.2b already covers it — skip here. Otherwise apply the **blast-radius idiom** from the canonical section (do NOT re-derive it): extract changed surfaces from the diff and grep `{SPEC_DIR}` for each — (1) ROUTE literals + `*Path`/`*Base`/`*_URL` consts; (2) user-visible COPY strings (especially REMOVED copy a spec still asserts = guaranteed break); (3) `data-testid` values; (4) API/SSE endpoint paths (`page.route("**/...")`). Emit `affected_specs` as `file:line + matched token`. The drift this prevents is real and recurring — `/word-addin/analyze`→`/v1/analyze` versioning, `"Ask about your document"`→`"Document Assistant"`, GET-poll→SSE, header class-selectors→semantic markup, `"Create Playbook"`→`"Add Playbook"` (live un-caught drift at `playbooks-v2-move-positions.spec.ts:58`).

**Then UNION Tier 0 — the profile's `feature_map` (canonical §2b "Related-spec selection & execution target").** The token grep is Tier 1 (precision); it is blind to behavior changes that break a spec without renaming any token — which is why every §3.2c firing before 2026-07-10 ended `NO_AFFECTED`/`FLAGGED` while the nightly still caught scoped breaks. For each changed file, prefix-match against `e2e.feature_map` entries (`"app-prefix => spec-path"`; every matching entry contributes) and add those spec paths to `affected_specs` tagged `feature-map:{prefix}`. A changed file matching `e2e.shared_paths` adds `e2e.smoke_specs` (bounded canary) — NEVER the whole suite; full regression is the nightly's job. Profile lacks the §2b keys → Tier-1-only (status quo), note it in the report.

**Step 3 — Run a bounded subset, or FLAG.**
- **Sideload-only repos** (`sideload_only: true` — GDocs `test/e2e/`, Word Add-in tier): the e2e tier targets the real dev API and needs `.env.test.local` creds (nightly / manual-dispatch). Browser-driven verify cannot run it. **FLAG only:** "N affected specs in `{SPEC_DIR}` assert surfaces this diff changed — run them in the nightly/manual e2e tier before merge." Never auto-run.
- **Runnable repos** (e.g. addin-fe): pre-merge, the run MUST target the **local dev server serving this branch** — the config's default baseURL is DEPLOYED dev, which pre-merge serves the code *without* the branch, so a green there proves nothing about the change and a red is usually the old deploy, not a bug (this is why pre-2026-07 firings only ever FLAGGED). Canonical: testing-patterns §2b.
  ```bash
  LOCAL=$(grep -A60 '^e2e:' "$PROFILE" | grep 'local_base_url:' | awk '{print $2}' | tr -d '"')   # fallback below is an example — record e2e.local_base_url in the repo profile
  up=$(curl -sk -o /dev/null -w "%{http_code}" "${LOCAL:-https://localhost:3002}" --max-time 3)
  # cap at 5 to keep verify bounded — order: in-diff specs → Tier-1 token hits →
  # Tier-0 specs sharing a filename token with a changed file's basename → remainder alphabetical
  PLAYWRIGHT_BASE_URL="${LOCAL:-https://localhost:3002}" ${RUN_CMD:-yarn test:e2e} {first ≤5 affected_specs} --workers=1 --reporter=line
  ```
  Auth is domain-scoped — never `REUSE_AUTH=true` across targets; the setup project re-logs-in from `.env` `TEST_USER_EMAIL`/`TEST_USER_PASSWORD` (§2b gotchas). Local server DOWN (`$up` not 2xx/3xx) → AskUserQuestion: **(a)** "I started `yarn dev` — run now" (re-probe, then run) or **(b)** "Flag for the post-deploy re-check" → result `DRIFT_FLAGGED (local-server-down)`. Never silently fall back to deployed dev pre-merge.
  Record pass/fail per spec, naming any failing test. Per [[feedback_e2e_rot_not_blocking]] a run failure is a **real finding but NEVER an auto-block** — report it, clamp per §7, do not flip the verdict to a hard block on the strength of an E2E red alone. If creds do NOT resolve → FLAG instead: "these N specs likely need updating — couldn't run (no creds)."

**Step 4 — Parse SKIPPED affected specs as coverage debt.** For every affected spec that is FLAGGED-not-run (sideload-only or no-creds) OR that runtime-**skips** when run (a `test.skip` or an `isVisible().catch(()=>false)`→skip guard fired on a surface this diff changed), treat it as coverage debt: the drift is exactly what a skip-guard hides as false-green. Surface each in the report and feed the §7 clamp row below.

**Step 5 — Persist the FULL affected list for the post-deploy re-check.** The ≤5 cap bounds /verify's wall-time, not the coverage. Write the uncapped list into the ticket state file so `/ci-check` §5 can offer the scoped re-run against deployed dev once the merge is deployed (merged ≠ deployed — [[reference_diagnosing_stuck_dev_deploy]]):

```markdown
## E2E Affected Specs (post-deploy re-check)
<!-- written by /verify §3.2c; consumed by /ci-check §5.1b -->
- e2e/playbooks/playbooks-v2-position-detail.spec.ts   (token: "position-guidance")
- e2e/playbooks/                                        (feature-map: app/_lib/playbooks/)
- e2e/home.spec.ts                                      (smoke: app/_common/ touched)
run: {RUN_CMD} {spec paths} --workers=1 --reporter=line   # default baseURL (deployed dev) — AFTER deploy lands
```

This section replaces "wait for the nightly full regression to discover a scoped break" — the same related-only list, run at the moment it becomes meaningful.

**Result codes (consumed by §7):**
- `OK` — affected specs ran and passed (drift covered, green).
- `DRIFT_RUN_FAIL` — an affected spec ran and failed → real finding, named in report, clamp per §7, never an auto-block.
- `DRIFT_FLAGGED` — affected specs identified but not run (sideload-only OR no creds/base-url) → coverage debt.
- `DRIFT_SKIPPED` — an affected spec runtime-skipped (test.skip / catch→skip guard) on a changed surface → coverage debt, false-green risk.
- `NO_AFFECTED` — diff changed app surfaces but no spec in `{SPEC_DIR}` asserts them (clean).
- `NOT_RUN_NO_E2E` — repo not e2e-enabled (Step 1 silent no-op; this code is internal, not printed).

State file event log:
```
- [verify-e2e-drift HH:MM] spec_dir={SPEC_DIR} affected={N} target={local|deployed-dev|not-run} result={OK|DRIFT_RUN_FAIL|DRIFT_FLAGGED|DRIFT_SKIPPED|NO_AFFECTED} failing=[...] flagged=[...] skipped=[...]
```

### 3.3 Simplify Check

Review the changed code for reuse opportunities, code quality, and efficiency:
- Are there duplicated patterns that could be extracted into a shared utility/hook/component?
- Are there overly complex functions that could be simplified?
- Are there existing utilities in the codebase that the new code reinvents?
- Are there unnecessary abstractions or over-engineering?

This is the same check that the built-in `/simplify` skill does, but targeted at the ticket's modified files only. If issues are found, present them as suggestions (not blockers) alongside the verification report.

**API endpoint verification:** If any AC involves API calls, verify the endpoints exist in the swagger definitions:
```bash
grep -i "endpoint-path" $WORKSPACE_ROOT/.claude/api-reference/*.json 2>/dev/null
```
Flag any API calls to endpoints not in the swagger — they may need BFF work or a new backend endpoint.

### 3.4 Comment Hygiene Gate (blocks READY-FOR-PR)

Noise comments turn the codebase into spaghetti. A comment earns its place ONLY if it states a non-obvious constraint or gotcha a future reader genuinely cannot infer from the code. **Default is NO comment** — names, types, and the commit message carry intent. Standing rule: memory `feedback_no_bug_letter_comments` + every repo's `codebase-patterns.md` § "Code comment hygiene". Scan the comments ADDED by this change — not the whole file.

**Mechanical pass** — ticket numbers, section/spec refs (`§16`, `NEW-2`), acceptance-criteria refs (`AC3`), bug-letter labels, and before→after history are never acceptable in a comment; flag every match with `file:line` and the text:
```bash
git diff {BASE}...HEAD -- '*.ts' '*.tsx' '*.js' '*.jsx' '*.css' '*.scss' '*.go' '*.swift' '*.py' \
  | grep -nE '^\+' \
  | grep -iE '(//|/\*|\*|#).*(PROJ-[0-9]+|§|NEW-[0-9]|\bAC[0-9]|Bug [A-Z]\b|used to be|previously|formerly|fix-forward|the first fix|no longer|changed from|is a word, not|, not a )'
```

**Judgment pass** — for every OTHER comment added in the diff, ask one question: *does this state a constraint a maintainer couldn't infer, or is it narrating my reasoning / restating the code / explaining why the diff is correct?* If the latter, flag it. Canonical garbage that must be caught: `/* "Unlimited" is a word, not a balance — match profile-row-value */` on a `.credit-count-unlimited` rule — the selector name + values already say it, and the "why" belonged in the commit message (where it already was, verbatim).

**Action:**
- Any flagged comment → verdict is **ISSUES FOUND** (not READY-FOR-PR) until removed or the user explicitly justifies a specific one. Removing a noise comment is a trivial code change — do it and re-run the gates, don't merely report it.
- If flagged comments remain at summary time, cap the score at 85%.
- A diff that adds zero comments is the healthy, common case — record "clean" and move on. Never invent a need for a comment.

## 4. Display Code Verification Results

Present the verification report to the user with:
- Per-AC status table (VERIFIED / FAILED / NEEDS_MANUAL_CHECK)
- Quality gates results
- Test results
- Gaps found (if any) with specific fix suggestions

## 5. Live URL & UI Verification (Playwright)

**Skip if** Playwright MCP tools are not available or dev server is not running.

For each AC that involves a URL, page, or UI component:

1. **Navigate to the feature URL** using Playwright:
   ```
   mcp__playwright — navigate to {dev_server_url}/{feature-path}   (e.g. https://localhost:3002 — record your dev server URL in the repo profile)
   ```
   If the page requires auth, Playwright will see the login page — note it as NEEDS_AUTH and skip to next URL.

2. **Check the page loads** — no error screens, no blank pages, no console errors. Read the accessibility tree to verify key elements are present.

3. **For API-dependent ACs** — check that the page shows real data, not loading spinners stuck forever or error states. If the page shows an error, capture it:
   ```
   mcp__playwright — take screenshot of the current page
   ```

4. **For form/interaction ACs** — fill forms, click buttons, verify the expected result appears:
   ```
   mcp__playwright — click "Save" button
   mcp__playwright — verify success message appears
   ```

5. **Report findings:**
   - URL_OK: page loads with expected content
   - URL_ERROR: page shows error (capture screenshot + error message)
   - URL_TIMEOUT: page didn't load (dev server might be down)
   - INTERACTION_OK: form/button flow works
   - INTERACTION_FAIL: expected result didn't appear

If Playwright is not available, ask the user to verify URLs manually.

## 6. Contract Smoke Test (API Integration Tickets)

**Skip if** the ticket has no API integration (no useQuery/useMutation in changed files).
**Skip if** ticket classification (from state file) is `trivial`.

**Prefer the agent.** If `$WORKSPACE_ROOT/.claude/agents/contract-verifier.md` exists, invoke it:

```
Task(
  subagent_type: "contract-verifier",
  description: "Contract check for PROJ-XXXX",
  prompt: "Verify API contract for these endpoints.
    endpoints: {list extracted from modified files in Step 6.1}
    ts_types_paths: {modified files that contain interface or type definitions}
    swagger_paths: [$WORKSPACE_ROOT/.claude/api-reference/*.json]
    live_base_url: {dev_server_url from repo profile, or empty}
    auth_cookie_env: COOKIE
    mode: auto
    consumer_repos: [{other repo names if the ticket is cross-repo auth/identity}]"
)
```

Use the agent's report verbatim in the "## Contract Smoke Test Results" section of the verification output. The agent already formats the per-endpoint table, mismatch count, and recommended actions.

**Fallback (inline).** If the agent is not available, fall back to the bash-heavy flow below (Steps 6.1 through 6.5).

### 6.1 Detect API Endpoints in Changed Files

```bash
# Find all API hooks in modified files
grep -n "useQuery\|useMutation\|useFetch\|fetch(\|axios\." {modified_files} 2>/dev/null
# Extract endpoint URLs
grep -n "api/\|/v[0-9]/\|endpoint\|queryKey\|mutationFn" {modified_files} 2>/dev/null
```

If no API calls found in modified files, skip this phase.

### 6.2 Check Cache for Recent Results

```bash
ls {REPO_ROOT}/.claude/tickets/PROJ-XXXX-contract.md 2>/dev/null
```

If the contract report exists and is less than 1 hour old, use cached results:
```bash
find {REPO_ROOT}/.claude/tickets/PROJ-XXXX-contract.md -mmin -60 2>/dev/null
```

### 6.3 Auth & Environment Check

Try to reach the BFF or dev API in this priority order (curl examples below use `https://localhost:3002` — substitute your dev server URL from the repo profile):

1. **BFF with session cookie** — check `.env.local` or `.env.development` for session cookies:
   ```bash
   grep -i "cookie\|session" {REPO_ROOT}/.env.local {REPO_ROOT}/.env.development 2>/dev/null   # add your app's session-cookie name to the pattern
   ```
   If found, test reachability:
   ```bash
   curl -s -o /dev/null -w "%{http_code}" -b "$COOKIE" https://localhost:3002/bff/api/health -k --max-time 5 2>/dev/null
   ```

2. **If no cookie or BFF unreachable, fall back to swagger comparison** — use `.claude/api-reference/` JSON files. Compare TypeScript types against swagger schema definitions. No auth needed — this is static analysis.

3. **If neither possible**, add warning and skip:
   > "Contract smoke test skipped — no auth available and swagger may be stale. Manual verification recommended."

### 6.4 Run Contract Checks

**For each GET endpoint the ticket touches:**

**If BFF is reachable (live check):**
```bash
# Fetch actual response
curl -s -b "$COOKIE" "https://localhost:3002/bff/api/{endpoint}" -k | jq 'if type == "array" then .[0] else . end' > /tmp/actual-response.json

# Extract TypeScript type from codebase
grep -A 30 "type\|interface" {type_file} > /tmp/expected-type.txt
```

Compare field-by-field:
- Missing fields in actual response that TypeScript expects as required → ❌
- Fields present as `null` that TypeScript expects as non-nullable → ❌
- Fields that are objects where TypeScript expects strings (or vice versa) → ❌
- Extra fields in actual response not in TypeScript → ⚠️ (informational)

**For GET endpoints with filter/search params:**
Make TWO requests — with and without the param:
```bash
curl -s -b "$COOKIE" "https://localhost:3002/bff/api/{endpoint}" -k > /tmp/unfiltered.json
curl -s -b "$COOKIE" "https://localhost:3002/bff/api/{endpoint}?{param}={value}" -k > /tmp/filtered.json
diff /tmp/unfiltered.json /tmp/filtered.json
```
If responses are identical → ⚠️ "Backend may not implement this filter param. Verify with backend team."

**If falling back to swagger comparison (static check):**
- Read the relevant swagger JSON from `.claude/api-reference/`
- Compare the swagger `definitions` section against the TypeScript interfaces
- Flag any structural mismatches (field names, types, required vs optional)
- Note: "This is a static comparison against swagger — swagger may be stale. Live verification recommended."

**For mutations (POST/PUT/DELETE):**
- Do NOT execute mutations
- Flag: "Mutation endpoint detected: {method} {endpoint}. Manual post-merge verification recommended."
- If the mutation creates/updates a resource and the ticket also lists that resource, flag:
  > "⚠️ This ticket includes a mutation + list/detail refetch. If backend uses eventual consistency (DynamoDB), verify optimistic cache updates are implemented — refetchQueries alone may return stale data."

### 6.5 Write Contract Report

Write detailed results to `{REPO_ROOT}/.claude/tickets/PROJ-XXXX-contract.md`:

```markdown
---
ticket: PROJ-XXXX
generated: YYYY-MM-DDTHH:MM:SSZ
method: live | swagger-static
---

## Contract Smoke Test: PROJ-XXXX

### Endpoints Tested
| Endpoint | Method | Result | Details |
|----------|--------|--------|---------|
| /api/v2/positions | GET | ✅ | Response matches PositionListResponse |
| /api/v2/positions?ownership=MINE | GET | ⚠️ | Identical to unfiltered — backend may not implement param |
| /api/v2/positions/:id | GET | ❌ | actions[].action is object, frontend expects string |
| /api/v2/positions | POST | ⚠️ | Mutation not tested — manual verify recommended |

### Mismatches Found
{detailed field-by-field comparison for any ❌ results}

### Warnings
{list of ⚠️ items}
```

Show summary inline in the verification output:
```
## Contract Smoke Test Results ({method} mode)
✅ {N} endpoints match  |  ⚠️ {N} warnings  |  ❌ {N} mismatches
Full details: .claude/tickets/PROJ-XXXX-contract.md
```

**BLOCKING RULE:** If any ❌ mismatches exist, do NOT mark the ticket as DONE. Status must be "ISSUES FOUND (contract mismatch)".

## 6.5b Security Quick-Scan (Automatic)

Run a lightweight security check on modified files — this is NOT the full `/security` audit, just the essentials:

```bash
# Secrets in changed files
grep -n "AKIA[0-9A-Z]\{16\}\|sk-[a-zA-Z0-9]\{48\}\|sk_live_\|password\s*=\s*['\"]" {modified_files} 2>/dev/null

# Silent error swallowing (the "Fail Loud" check)
grep -n "catch.*{}\|catch.*return\s*{}\|catch.*return\s*\[\]\|catch.*return\s*null" {modified_files} 2>/dev/null

# console.log left in
grep -n "console\.log" {modified_files} 2>/dev/null
```

Flag any findings as **SECURITY** or **FAIL_LOUD_VIOLATION** in the report.

## 6.5c Out-of-Scope Findings — Name the Owner With Evidence

When a finding is judged out-of-FE-scope / backend-side, do NOT name the owning repo from memory. Resolve it before reporting:
1. Read `$WORKSPACE_ROOT/.claude/stack-connections.md` for the domain's upstream service + the Go client that calls it
2. Grep the relay lambda: an opaque `map[string]interface{}` pass-through proves the field is computed further upstream (engine-side), not relay-side
3. State the owning repo + the `file:line` that proves ownership, and whether a relay-side stopgap is possible

A loosely-named owner ("the engine / the upstream AI service, probably") costs a round-trip and risks filing tickets against the wrong repo — pinning [[PROJ-6214]]'s positionId bug to `your-org/ai-engine` took two user pushbacks that this protocol would have avoided.

## 7. Verification Summary with Confidence Score

The verdict carries a **computed confidence score (0–100%)**, not a self-reported level. The score is arithmetic over the gate table — `passed_gates / total_gates`, then caps — computed by `.claude/scripts/verify-score.py`, never by the model. 100% is reachable ONLY when every machine gate passed with a valid receipt AND every human gate carries a recorded confirmation (design: `docs/verify-confidence-score.md`).

### Gate states (exactly three)

| State | Meaning | Requirement |
|---|---|---|
| `PASS` | Machine-verified true | Receipt attached |
| `FAIL` | Machine-verified false | Receipt attached (showing the failure) |
| `UNVERIFIED` | No machine evidence possible in this environment | Names the human step + QA method that confirms it |

- A machine-verifiable gate **without a receipt counts as FAIL**, not PASS — an unevidenced claim never scores.
- Human-only gates (visual correctness on a sideload-only surface, deployed-env behavior) are **born UNVERIFIED** and flip only when a `[qa-confirmed via {method}]` event lands in the state file. The model may never flip them itself. Always record the *method* (in-app QA, screenshot compare, deployed walkthrough — /qa names it): the recorded method is the audit trail when a sign-off later proves wrong.

### Receipts

Every PASS/FAIL gate carries: the exact command run, its exit code, ≤3 verbatim output lines, and `file:line` when the claim is about code. Receipts are spot-checkable (`grep -F`); a receipt whose quoted evidence can't be found caps the score at 30% and flags the gate.

### Title Achievement Check (a BLOCKING gate)

Per-AC code-existence can all pass while the title's promise stays unmet. If the ticket title carries an action verb — `(remove|integrate|wire|ship|replace|migrate) X` — verify the promise against user-visible reality:

- **"remove X"** → `grep -rn "X" {REPO_ROOT}/app/ --include='*.ts*'` excluding tests/fixtures. Production matches = title NOT achieved.
- **"integrate / wire / ship / replace X"** → identify the single user-visible artifact (a network request, a screen, a click outcome) and inspect its actual call path. Still mocked/stubbed = title NOT achieved.

Title verb unmet → **Title Verb gate = FAIL `[BLOCKING]` → score capped at 30%** with reason `title promise unmet: {detail}`, and add a **Title Verb** row to the gate table. ([[PROJ-6214]] "Integrate Backend APIs (remove mock data)" scored 2/9 ACs yet reported MEDIUM — the picker still ran a 2s setTimeout mock any fresh reviewer would have clicked into immediately.)

### Compute the Confidence Score

Build the gate table from: per-AC gates (exists / substantive / wired, §3.1) + standard battery (lint, types, tests, build, contract — tests/types/build are `[BLOCKING]`) + Title Achievement `[BLOCKING]` + surface gates (visual/manual checks on surfaces the harness can't drive → born UNVERIFIED). Then:

```
raw   = passed_gates / total_gates
caps  (worst wins):
  any [BLOCKING] gate FAIL          -> cap 30%   "this will break"
  any receipt spot-check mismatch   -> cap 30%   "claimed evidence not found"
  any gate UNVERIFIED               -> cap 70%   "human confirmation pending"
  any quality cap from tables below -> cap 85%   (legacy clamp HIGH→MEDIUM)
```

Quality-cap findings from the Visual-Aware / E2E-Drift / Comment-Hygiene tables enter the gate table as `FAIL` (or `UNVERIFIED`) rows tagged `[CAP85]` — that tag is how the scoring script sees them; a cap described only in prose does not exist.

| Band | Reading |
|---|---|
| 90–100 | Ship — everything evidenced, humans confirmed |
| 70–89 | Medium — machine-green but human gates pending / quality caps applied; model output alone can NEVER raise the score past this band |
| 31–69 | Gaps — failed or unevidenced gates, named individually |
| ≤30 | Will break — a blocking gate failed or claimed evidence didn't check out |

**Gate-list adjustments based on ticket classification** (from state file `## Classification` section):
- **Trivial/config/deps**: contract gate not required — *excluded from the gate list* (not scored as UNVERIFIED)
- **Bugfix with API integration**: contract gate PASSes with at least a swagger comparison
- **Standard/Complex with API**: contract gate requires the smoke test; if the ticket spec lists E2E, the E2E gate is `[BLOCKING]`

**Visual-Aware Caps (HAS_VISUAL_SPEC or HAS_UI tickets):**

| Check | Result | Cap | Reason on verdict |
|---|---|---|---|
| `visual_compare` (static) | `STATIC_OK_RUNTIME_GAPS` | cap to **30%** | "Static CSS matches spec but runtime computed styles differ — CSS cascade/specificity override bug. Inspect with browser DevTools before merging." |
| `visual_compare` (runtime) | `NOT_RUN_RUNTIME` AND HAS_UI=true | cap 85% | "Runtime computed-style readback skipped (dev server unreachable or Playwright unavailable). Confirm in browser before merging." |
| `viewport_sweep` | `NARROW_VIEWPORT_BUG` | cap to **30%** | "Element renders incorrectly at 320/450px — Word Add-in always runs at this width. PR-blocking." |
| `viewport_sweep` | `BREAKPOINT_DRIFT` | cap 85% | "Element bounds shift unexpectedly between viewports — visual-spec doesn't declare this breakpoint behavior. Confirm intent." |
| `viewport_sweep` | `NOT_RUN` AND HAS_UI=true (browser-reachable surface) | cap 85% | "Viewport sweep skipped. Narrow-viewport behavior not verified." |
| `viewport_sweep` | `NOT_RUN_EXPECTED` (sideload-only surface) | **no cap** | report row: "Viewport sweep N/A — Office task-pane WebView can't be driven by browser Playwright; in-Word manual QA is the substitute. Confirm in-Word before merge." |
| `css_token_compliance` | `HARDCODED_VALUES_FOUND` | cap 85% | "Hardcoded color/spacing values found in modified CSS Modules. Use design tokens from globals.css unless explicitly approved." |
| `visual_compare` (coarse) | `GAPS_FOUND` | cap to **30%** | "{N} visual spec gaps — see Visual Spec Gaps table; fix before PR" |
| `visual_compare` (coarse) | `DEFERRED_TO_MANUAL` | cap 85% | "visual spec exists but Figma-only / `manual_review_required: true` — confirm with screenshot in-{environment}" |
| `visual_compare` (coarse) | `NOT_RUN` AND HAS_VISUAL_SPEC=true | cap 85% | "visual spec asserted but no spec file present — run `/clarify` Step 2.5b or attach a screenshot" |
| `visual_compare` | `OK` | no change | (none) |

**E2E-Drift Caps (§3.2c — e2e-enabled repos only):**

| §3.2c result | Cap | Reason on verdict |
|---|---|---|
| `DRIFT_FLAGGED` (affected specs flagged-not-run: sideload-only, no creds, or local dev server down) | cap 85% | "{N} e2e specs in `{spec_dir}` assert surfaces this diff changed but were not run — drift coverage unverified. Start `yarn dev` and re-run /verify, or run the state file's post-deploy re-check (§3.2c Step 5) after merge+deploy." |
| `DRIFT_SKIPPED` (an affected spec runtime-skipped via test.skip / isVisible-catch→skip guard on a changed surface) | cap 85% | "{N} affected e2e specs runtime-skipped on a surface this diff changed — a skip guard is hiding the drift as false-green. Re-enable/repair before relying on E2E." |
| `DRIFT_RUN_FAIL` (an affected spec ran and failed) | cap 85%, name the failing test | "Affected e2e spec {file} failed against the changed surface — real finding, NOT an auto-block ([[feedback_e2e_rot_not_blocking]]); update the spec or the change before merge." |
| `OK` / `NO_AFFECTED` / not e2e-enabled | no change | (none) |

Per [[feedback_e2e_rot_not_blocking]], NONE of these flip the verdict to a hard block on their own — they cap the score and name the finding. The cap targets the false-green this session is built to prevent (162 skipped specs = 21% hiding drift; live un-caught drift at `playbooks-v2-move-positions.spec.ts:58`).

**Comment Hygiene Gate (3.4):** if any noise comments remain unaddressed at summary time → verdict is **ISSUES FOUND** (not READY-FOR-PR), and cap the score at 85%. These are trivial to remove — fix and re-run; never ship garbage comments to keep a high score.

The visual-aware cap is the load-bearing safeguard against a false ship-band score on UI tickets where the implementation drifts from the design without breaking any test. Applied retroactively to [[PROJ-6086]] and [[PROJ-6087]] (which shipped at ship-band and failed QA on visual fidelity), the cap would have held both at 85% with the reason "visual spec asserted but not directly verified" — prompting in-app QA before merge.

### Present Summary

```markdown
## Verification Report: PROJ-XXXX

### Score: {NN}% ({passed}/{total} gates) — {band reading}
Caps applied: {`[BLOCKING] {gate} FAIL → 30%` | `UNVERIFIED {gate} → 70%` | `{quality cap} → 85%` | none}

### Gate Table
| Gate | State | Receipt / Owner |
|------|-------|-----------------|
| Reflexion (self-critique) | PASS | {N concerns found} |
| AC-{n} exists / substantive / wired | PASS / FAIL | {cmd, exit code, file:line — one row per AC gate} |
| Substance Checks | PASS / FAIL | {FILE MAP, TEST SPEC — cmd + exit} |
| Title Verb `[BLOCKING]` | PASS / FAIL | {grep cmd + hits} |
| Lint `[BLOCKING]` | PASS / FAIL | {cmd, exit code} |
| Types `[BLOCKING]` | PASS / FAIL | {cmd, exit code} |
| Unit tests `[BLOCKING]` | PASS / FAIL | {cmd, exit code, "{N} passed" line verbatim} |
| Pattern Compliance | PASS / FAIL | {N violations or clean} |
| Comment Hygiene (3.4) | PASS / FAIL | {file:line list — blocks PR until removed} |
| Contract Smoke Test | PASS / FAIL / (excluded for trivial) | {method + result} |
| Visual Spec Compare | PASS / FAIL / UNVERIFIED | (only when HAS_VISUAL_SPEC) |
| Security Quick-Scan | PASS / FAIL | {clean / N findings} |
| Visual: {surface check} | UNVERIFIED | human: {QA method from /qa — e.g. in-app QA at target viewport} |
| E2E Tests | PASS / FAIL / (excluded if not specified) | {cmd, exit} |
| E2E Drift (3.2c) | PASS / FAIL | (only on e2e-enabled repos) |

Run `.claude/scripts/verify-score.py {report-file}` to compute the score — never hand-write the percentage.

### Verdict: READY FOR PR / ISSUES FOUND
{If ISSUES FOUND, list each blocking issue}
{If any UNVERIFIED gates: "Max score until human confirmation: 70%. Confirm via {method}, then record `[qa-confirmed via {method}]` to lift."}
```

## 8. Update Ticket State

If `{REPO_ROOT}/.claude/tickets/PROJ-XXXX.md` exists, update:
- Verification phase → DONE (if all pass) or IN_PROGRESS (if gaps)
- Record the gate table and computed score
- Add event log entry: `- [HH:MM] Verified: {N}/{total} ACs, score {NN}% (caps: {list|none}), contract {verified/unverified/N mismatches}, security {clean/N findings}, sha={git rev-parse --short HEAD}` — the `sha=` token is load-bearing: `/pr` §5.5b compares it to HEAD to detect ad-hoc commits made after verification (stale-verify warning)
- When the user later confirms a human gate, append: `- [HH:MM] [qa-confirmed via {method}] {gate name}` — re-running /verify then lifts the 70% cap without re-running machine gates

The ticket status line should read:
```
Status: DONE (Score: {NN}% — {band reading; name any caps})
```
Not just `Status: DONE`.

## 8.5 UI Iteration Capture (UI tickets only — feeds /learn meta-learning)

**Fires only when this verify exercised UI fidelity** — i.e. a `PROJ-XXXX-visual-spec.yaml` exists for the ticket OR the `ui-fidelity` agent / `visual_compare` ran this pass. Backend tickets never see it. **Fire once per ticket:** skip if the state-file Event Log already has a `ui-iteration` entry.

This is the ONE reliable moment to capture design-iteration cost — `/qa` is often skipped, and no automated stage (CI, merge) can tell whether the design was actually *right*. So ASK, don't infer. One `AskUserQuestion`, answerable in a tap:

- **Q1 — "How many back-and-forth rounds did this UI take until the design was actually RIGHT?"** → `1 (right first time)` | `2–3` | `4+` | `Still not right`
- **Q2 (only if Q1 ≠ "1") — "What finally made it right?"** (single-select; controlled vocabulary that maps to the `ui-fidelity` agent's sections):
  - `source-format` — the design source (Figma/screenshot/sibling) was resolved late / the extractor ran blind
  - `per-state-contract` — a state the mock didn't show (hover/empty/overflow/inactive/mixed v1-v2)
  - `scope-surface` — wrong surface, v1-vs-v2, or shared-vs-feature confusion
  - `token-value` — a color/spacing/radius mapping
  - `other` — one-line free text

Derive `surface` and `source` (`figma|screenshot|sibling|verbal|mixed`) from the ticket's `design_reference` (the same values passed to the `ui-fidelity` agent in §2.6); don't re-ask them.

**Write two places (both append-only, neither blocks the pipeline):**
1. State-file Event Log: `- [HH:MM] /verify: ui-iteration rounds={1|3|4|99} correction={class} source={src} surface={surface}` (`2–3`→3, `4+`→4, `Still not right`→99).
2. The repo's iteration ledger `{REPO_ROOT}/.claude/ui-fidelity-ledger.md`, under its `## AUTO:ITERATION-LOG` region (create the file + region if absent): `- YYYY-MM-DD PROJ-XXXX surface={surface} rounds={N} correction={class} source={src}`.

**Graceful degradation (the design depends on it):** the prompt is a survey, never a gate. If the user dismisses/skips it, write `rounds=unrecorded` to the Event Log (marks it seen so it never re-nags) and proceed to `/pr` unblocked. NEVER fabricate `rounds=1` on a skip — `/learn` §2.7 excludes `unrecorded` from the KPI mean, so absence never reads as success. A `Still not right` (99) is recorded but excluded from the down-trend mean and counted as an open-failure for its class.

**Non-UI tickets: no survey.** Their iteration cost is machine-readable — `/pr` §8 writes a `## Process Summary` (sessions, phases, fix_iterations, debug links) into the state file from the Event Log, and `/learn` §2.7b distills it. The survey above exists only because *design rightness* can't be counted from disk; AC-fix iterations can.

</process>

<success_criteria>
- [ ] Target repo detected
- [ ] ACs gathered from ticket state, Jira, arguments, or user input
- [ ] Modified files identified
- [ ] Each AC verified against actual code (not just task completion)
- [ ] Quality gates run using repo-specific commands
- [ ] Comment Hygiene Gate (3.4) run on the diff — no noise/narration comments shipped
- [ ] Tests run for modified files
- [ ] Visual verification performed (if screenshot tooling available)
- [ ] Verification report produced with per-AC status
- [ ] **Score computed by `verify-score.py`, not hand-written** — every PASS/FAIL gate has a receipt; every UNVERIFIED gate names its human QA method; caps applied worst-wins
- [ ] Ticket state file updated (if exists)
- [ ] **UI-iteration capture (§8.5):** on UI tickets only, the one-tap rounds-to-right + correction-class prompt was offered at the end of verify; result written to the Event Log + `ui-fidelity-ledger.md` `AUTO:ITERATION-LOG`; a skipped prompt recorded as `rounds=unrecorded` (never fabricated), pipeline never blocked

## Related Commands
- Before: /ticket (implements the ACs being verified)
- After: /pr (generate PR once verified)
- Testing: /test | /e2e
- Patterns: codebase-patterns.md | testing-patterns.md
</success_criteria>
