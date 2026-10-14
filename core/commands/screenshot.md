---
name: screenshot
version: 0.10.1
description: Capture a screenshot of any page or component in the running app.
argument-hint: "/url-path [name] [--selector .css] [--mobile] [--full-page]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - AskUserQuestion
---
> **Model floor: sonnet** — drives a capture script. This is guidance, not a pin: the command inherits the session model. Opus adds nothing here; Sonnet keeps its full power.

<objective>
Capture a screenshot of a page or specific component using Playwright (or similar tool).
Screenshots are ephemeral (stored in /tmp), viewable by Claude, and presented to the user for review.
Detects the target repo and adapts to its screenshot tooling.
</objective>

<process>

## 0. Detect Target Repository

1. **Check current working directory** — if CWD is inside a sub-repo of `$WORKSPACE_ROOT/{repo-name}/`, use that repo. **IMPORTANT:** `$WORKSPACE_ROOT/` itself is NOT a valid target — it's the workspace root. Only match if CWD is at least one level deeper.
2. **Parse $ARGUMENTS** for repo hints
3. **If still ambiguous**, check for repos with active tickets or recent changes, then **always ask the user** using `AskUserQuestion`:
   ```bash
   for dir in $WORKSPACE_ROOT/*/; do
     ls "$dir/.claude/tickets/"*.md 2>/dev/null
   done
   ```

Check if the repo has screenshot tooling:
- `{REPO_ROOT}/.claude/scripts/capture-screenshot.js` → Playwright-based capture
- If no script exists, inform the user: "This repo doesn't have automated screenshot tooling. You'll need to take screenshots manually."

**If `{REPO_ROOT}/CLAUDE.md` does NOT exist**, warn the user:
> "This repo ({REPO_NAME}) doesn't have a CLAUDE.md. I won't know the app's base URL, dev command, or route structure. You'll need to tell me the URL to capture."

## 1. Gather Context

### Check for active ticket
```bash
ls {REPO_ROOT}/.claude/tickets/*.md 2>/dev/null
```
If an active ticket exists, read it to understand:
- What ticket is being worked on (PROJ-XXXX)
- What ACs involve UI changes
- What files have been modified

### Check current branch changes
```bash
git -C {REPO_ROOT} diff --name-only main...HEAD 2>/dev/null
```
Use modified file paths to infer which app routes/screens might be affected.

## 2. Parse Arguments

Parse $ARGUMENTS for:
- **URL path**: First argument starting with `/` (e.g., `/tickets`, `/documents/123`)
- **Name** (optional): Argument not starting with `/` or `--`, used as filename
- **Flags** (optional):
  - `--selector ".css-selector"` — Capture a specific element
  - `--mobile` — Mobile viewport (375x812)
  - `--tablet` — Tablet viewport (768x1024)
  - `--full-page` — Full scrollable page
  - `--wait ".selector"` — Wait for element before capturing
  - `--ticket PROJ-XXXX` — Group under specific ticket folder

### If no URL path provided:

Use the context gathered in Step 1 to suggest pages. Ask the user which page to capture.

## 3. Build and Run

Determine ticket context:
- If `--ticket` flag provided, use that
- Else if active ticket state file found, use its ID
- Else use `adhoc`

Determine viewport:
- `--mobile` → `--viewport 375x812`
- `--tablet` → `--viewport 768x1024`
- Default → `1280x720`

Determine name:
- If provided, use it
- Else derive from URL path (e.g., `/tickets/123` → `tickets-123`)

```bash
cd {REPO_ROOT} && node .claude/scripts/capture-screenshot.js \
  --url "{url_path}" \
  --name "{name}" \
  --ticket {ticket_or_adhoc} \
  [--selector "{selector}"] \
  [--viewport "{WxH}"] \
  [--full-page true] \
  [--wait "{selector}"]
```

## 4. View and Present

1. Read the screenshot using the Read tool (Claude can view images)
2. Describe what you see in the screenshot
3. Tell the user the file path: `/tmp/claude-screenshots/{ticket}/{name}.png`
4. Ask if they want to capture another view or a specific component

</process>

<examples>

```
/screenshot /tickets
→ Captures the tickets list page

/screenshot /tickets/123 ticket-detail --selector ".MuiCard-root"
→ Captures just the card component on the ticket detail page

/screenshot /documents --mobile
→ Captures the documents page at mobile viewport (375x812)

/screenshot
→ (no args) Checks branch changes, suggests relevant pages, asks user which to capture
```

</examples>

## Related Commands
- QA: /qa (visual QA guide)
- Verify: /verify (verify visual changes)
- Debug: /project-debug (visual debugging)
