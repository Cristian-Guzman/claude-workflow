---
name: refactor
version: 0.10.1
description: Scan existing code against codebase-patterns.md, find violations, plan fixes, and refactor with full pattern enforcement.
argument-hint: "scope (e.g., orders-v2, app/_lib/tickets, or 'full')"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Write
  - Edit
  - Task
  - AskUserQuestion
  - EnterPlanMode
  - ExitPlanMode
  - TodoWrite
---
> **Model floor: opus** — pattern violations across a codebase. This is guidance, not a pin: the command inherits the session model. If you are a smaller model than the floor, say so in one line at the start and continue.

<objective>
Scan "$ARGUMENTS" against codebase-patterns.md and fix violations.
This is NOT /build (which creates new things). /refactor fixes EXISTING code to match established patterns.
Use this after AI-generated code was merged without proper pattern enforcement, or to bring legacy code up to standard.
</objective>

<process>

## 0. Detect Target Repository & Load Patterns

Determine which repository to work in:

1. **Parse $ARGUMENTS** for repo hints (e.g., "in addin-fe", "orders-v2 in addin-fe")
2. **Check current working directory** — if CWD is inside `$WORKSPACE_ROOT/{repo-name}/`, use that repo. **IMPORTANT:** `$WORKSPACE_ROOT/` itself is NOT a valid target.
3. **If still ambiguous**, list available repos and ask the user:
   ```bash
   ls -d $WORKSPACE_ROOT/*/CLAUDE.md 2>/dev/null
   ```

Once identified, store:
- **REPO_ROOT**: absolute path
- **REPO_NAME**: directory name

**Load repo config (read each if it exists):**
- `{REPO_ROOT}/CLAUDE.md` — conventions, commands, architecture
- `$WORKSPACE_ROOT/.claude/codebase-patterns-shared.md` if it exists — load first (shared rules); then the repo file
- `{REPO_ROOT}/.claude/codebase-patterns.md` — coding standards (**required for /refactor**)
- `{REPO_ROOT}/.claude/testing-patterns.md` — test patterns

**If `codebase-patterns.md` does NOT exist**, warn and ask:
> "This repo has no codebase-patterns.md — /refactor has nothing to enforce. Would you like to create one first (run /learn), or provide the rules you want enforced?"

## 1. Determine Scope

Parse $ARGUMENTS to identify what to scan:

| Input | Scope |
|-------|-------|
| Feature name (e.g., "orders-v2") | Scan `app/(web)/orders-v2/` and related dirs |
| File path (e.g., "app/_lib/tickets") | Scan that specific path |
| "full" or "all" | Scan entire repo source (warn: may be large) |
| Empty | Ask user what scope to refactor |

Resolve the scope to concrete file paths:
```bash
find {SCOPE_PATH} -name "*.ts" -o -name "*.tsx" | head -100
```

Check for active refactor sessions:
```bash
ls {REPO_ROOT}/.claude/refactors/*.md 2>/dev/null
```
If one exists for the same scope, ask: "Resume existing refactor or start fresh?"

## 2. Scan for Violations

Read `codebase-patterns.md` and extract each rule. Then scan the scope for violations:

### Common violation categories:

**Code Quality:**
- `any` types (search: `\bany\b` in .ts/.tsx files)
- Hardcoded colors (search: `#[0-9a-fA-F]{3,8}` in .tsx/.css — should use CSS variables)
- console.log left in code
- Missing error handling at API boundaries

**Component Patterns:**
- Native HTML inputs/selects instead of design system components (MUI, etc.)
- Duplicated code that should use `_common/` components
- Inline date formatting instead of Date component
- Components not following the repo's folder structure

**Import & Structure:**
- Wrong import patterns
- Missing barrel exports
- Files in wrong directories per repo conventions

**Testing:**
- Missing tests for modified/complex files
- Tests using wrong patterns (if testing-patterns.md loaded)

**Comment Noise (delete — refactoring INCLUDES removing garbage comments):**
A comment earns its place ONLY if it states a non-obvious constraint or gotcha a future reader genuinely cannot infer. Default is no comment — names, types, and git history carry intent. Standing rule: memory `feedback_no_bug_letter_comments` + `codebase-patterns.md` § "Code comment hygiene". The fix is **deletion** — no replacement comment.
- Mechanical (always a violation): ticket refs (`PROJ-\d+` — use your ticket project key), bug-letters (`Bug [A-Z]`), history narration (`used to be` / `previously` / `fix-forward` / `the first fix` / `no longer` / `changed from`), and chatty rationale that narrates *why the code is correct* or restates what the name/code already says.
  ```bash
  grep -rnE '(//|/\*|\*|#).*(PROJ-[0-9]+|Bug [A-Z]\b|used to be|previously|fix-forward|the first fix|no longer|changed from|, not a |is a word, not)' {scope paths} \
    --include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx' --include='*.css' --include='*.scss' --include='*.go' --include='*.swift'
  ```
  Canonical example to delete on sight: `/* "Unlimited" is a word, not a balance — match profile-row-value */`.
- Judgment: for every other comment in scope, keep ONLY if it names a real constraint a maintainer couldn't infer; otherwise mark for removal. Because these are pre-existing (not your additions), surface them in the Plan-Mode plan (Step 4) for approval rather than auto-deleting — then remove on approval.
- Severity: **warning** (noise comments accrete into spaghetti).

For each violation found, record:
- File path and line number
- Rule violated (reference codebase-patterns.md section)
- Severity: **critical** (breaks conventions), **warning** (suboptimal), **info** (style)

## 3. Create State File

Create `{REPO_ROOT}/.claude/refactors/{scope-slug}.md`:

```yaml
---
scope: {scope description}
repo: {REPO_NAME}
status: scanning | planning | implementing | verifying
created: YYYY-MM-DDTHH:MM:SSZ
updated: YYYY-MM-DDTHH:MM:SSZ
---

## Violations Found
| # | File | Rule | Severity | Status |
|---|------|------|----------|--------|
| 1 | path/to/file:42 | No hardcoded colors | critical | pending |

## Plan Summary
{filled after plan approval}

## Files Modified
{updated during implementation}

## Current Focus
{next violation to fix}

## Obsidian Links
- Repo: [[repos/{REPO_NAME}]]
- Patterns: [[codebase-patterns]] | [[testing-patterns]]
{if related tickets were mentioned in $ARGUMENTS or found during scanning, add: - Tickets: [[PROJ-XXXX]] (one link per ticket)}
```

## 4. Enter Plan Mode & Present Findings

Enter plan mode with `EnterPlanMode`. Present:

```markdown
# Refactor Plan: {scope}

## Violations Found
- **Critical:** X violations (must fix)
- **Warning:** X violations (should fix)
- **Info:** X violations (nice to fix)

## Critical Violations
1. `path/to/file:42` — [description] → Fix: [proposed change]

## Warning Violations
1. `path/to/file:15` — [description] → Fix: [proposed change]

## Implementation Order
1. [Group related fixes] → Depends on: nothing
2. [Next group] → Depends on: Step 1

## Risk Assessment
- Files affected: X
- Tests to update: X
- Breaking changes: [none / list]
```

**Wait for user approval.** User can approve all, select specific violations, or skip.

## 5. Implement Fixes

Exit plan mode and fix violations following the approved plan.

Use `TodoWrite` to track each fix. Key rules:
- Fix ONE violation category at a time (all hardcoded colors, then all any types, etc.)
- Run tests after each category to catch regressions early
- Update state file as fixes progress
- Follow codebase-patterns.md for the replacement code
- **Comment hygiene:** a refactor should usually REMOVE noise comments, never add them. Default to NO comment; never introduce ticket numbers (`PROJ-XXXX`), section/spec refs (`§16`, `NEW-2`), AC refs (`AC3`), bug-letters, or before→after history in a comment ([[feedback_no_bug_letter_comments]]). Enforced by the Comment Hygiene Gate in §6 and `/pr-creation`.

## 6. Verify

Run quality checks:
- Linting (from CLAUDE.md)
- Type checking
- Tests for modified files
- Full CI command if available
- **Comment Hygiene Gate (BLOCKING)** — scan comments ADDED by this refactor for ticket #, `§`/`NEW-n`/`ACn` refs, bug-letters, history narration, and reasoning-narration noise (and confirm you didn't leave noise comments you meant to delete). Canonical gate + grep: `/verify` §3.4. Any hit → strip and re-run.

Fix any issues introduced by the refactor.

## 7. Present Results

Show the user:
1. **Violations fixed** — count by category
2. **Files changed** — list with descriptions
3. **Violations skipped** — any that were deferred (with reason)
4. **Tests updated** — what changed
5. **CI status** — pass/fail

Update state file status to `completed`.

**DO NOT** create commits unless explicitly asked.

</process>

<guidelines>
- **Never change behavior.** Refactoring must preserve functionality. If a fix might change behavior, flag it and ask.
- **Fix in batches.** Group related violations (all color fixes, all type fixes) and verify between batches.
- **Don't over-refactor.** Fix what codebase-patterns.md says is wrong. Don't add improvements beyond the patterns.
- **Test between fixes.** Run tests after each batch to catch regressions immediately.
- **State file is mandatory.** Always create and update the refactor state file so /resume-ticket can pick up interrupted work.
</guidelines>

<success_criteria>
- [ ] Target repo detected and patterns loaded
- [ ] Scope resolved to concrete file paths
- [ ] Violations scanned and categorized (critical/warning/info)
- [ ] Comment-noise scan run — garbage/narration comments marked for deletion
- [ ] State file created at {REPO_ROOT}/.claude/refactors/
- [ ] Plan presented in plan mode with user approval
- [ ] Fixes implemented following codebase-patterns.md
- [ ] Tests pass after refactor
- [ ] CI passes
- [ ] State file updated throughout
- [ ] Results presented with violation counts
</success_criteria>

## Related Commands
- Source: codebase-patterns.md | testing-patterns.md (patterns to enforce)
- Verify: /verify (verify refactored code)
- Deliver: /pr-creation (generate PR)
- If interrupted: /resume-ticket
- Learn: /learn (after merge, extract new patterns)
