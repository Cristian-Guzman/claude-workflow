---
name: review-comments
version: 0.11.0
description: Fetch and triage PR review comments. Save valid feedback to the ticket state file for /learn to process later.
argument-hint: "PR-number [--repo repo-name]"
allowed-tools:
  - Read
  - Bash
  - Grep
  - Write
  - Edit
  - AskUserQuestion
---
> **Model floor: sonnet** — triage of review comments. This is guidance, not a pin: the command inherits the session model. Opus adds nothing here; Sonnet keeps its full power.

<objective>
Fetch review comments from a PR, present them for triage, and save the valid ones to the ticket
state file. This does NOT extract patterns — it just collects and stores reviewed feedback.
Pattern extraction happens later when you run `/learn`.

Use this after reviewers have commented on your PR. Not every comment is valid — reviewers
can be wrong, bots can be noisy, and some feedback is preference not convention. You decide
what's worth keeping.
</objective>

<process>

## 0. Detect PR & Repo

Parse $ARGUMENTS for a PR number. Detect repo from CWD.

```bash
cd {REPO_ROOT}
# Get PR details
gh pr view {PR_NUMBER} --json title,headRefName,author,state,reviews,comments
```

Extract the ticket ID from the branch name (e.g., `feat/[[PROJ-5835]]-...` → [[PROJ-5835]]).
Check if a ticket state file exists at `{REPO_ROOT}/.claude/tickets/PROJ-XXXX.md`.

If no PR number given, check for the current branch's PR:
```bash
gh pr view --json number,title 2>/dev/null
```

## 1. Fetch All Comments

```bash
# Inline code comments (the detailed ones)
gh api repos/{owner}/{repo}/pulls/{PR_NUMBER}/comments --jq '.[] | {user: .user.login, path: .path, body: .body, line: .original_line}'

# Review-level comments (approve/request changes)  
gh api repos/{owner}/{repo}/pulls/{PR_NUMBER}/reviews --jq '.[] | {user: .user.login, state: .state, body: .body}'
```

## 2. Filter Noise

Automatically skip:
- Bot comments from CI/linters (user login contains "bot" or "actions")
- Empty review bodies (approvals with no text)
- "LGTM", "looks good", "approved" with no substance

**Keep Copilot review comments** — they often catch real issues. But flag them as `[bot]` so the user knows the source.

## 3. Present for Triage

Show each comment and ask the user to classify it:

```markdown
## PR #{PR_NUMBER} Review Comments

### Comment 1 — {reviewer} on {file}:{line}
> "{comment text}"

Is this valid feedback?
- **keep** — valid, save to ticket state (will feed /learn)
- **skip** — not relevant or already fixed
- **disagree** — reviewer is wrong, note why

### Comment 2 — {reviewer} on {file}:{line}  
> "{comment text}"

keep / skip / disagree?

### Comment 3 — [bot] Copilot on {file}:{line}
> "{comment text}"

keep / skip / disagree?
```

For each "keep": ask for a brief note — what category is this?
> "One word: convention / architecture / testing / security / performance / other"

For each "disagree": ask why — this itself can be a learning signal.
> "Why disagree? (brief — this helps /learn understand your reasoning)"

## 4. Save to Ticket State File

If a ticket state file exists (`{REPO_ROOT}/.claude/tickets/PROJ-XXXX.md`), append:

### To the Event Log:
```markdown
- [HH:MM] PR #{PR_NUMBER} review: {N} comments triaged — {kept} kept, {skipped} skipped, {disagreed} disagreed
```

### New section (or append to existing):
```markdown
## Review Feedback (from PR #{PR_NUMBER})

### Kept
- [{category}] {reviewer} on {file}: "{summary of comment}" 
- [{category}] {reviewer} on {file}: "{summary of comment}"

### Disagreed (with reasoning)
- {reviewer} on {file}: "{comment}" — Disagreed: {user's reasoning}
```

If no ticket state file exists, create a standalone file at `{REPO_ROOT}/.claude/tickets/pr-{PR_NUMBER}-feedback.md`.

## 5. Summary

```markdown
## Review Comments Triaged

PR: #{PR_NUMBER} — {title}
Reviewer(s): {names}

- Kept: {N} comments ({categories breakdown})
- Skipped: {N}
- Disagreed: {N}

Saved to: .claude/tickets/PROJ-XXXX.md

Next: Run `/learn` when you have 3+ delivered tickets to extract patterns from this feedback.
```

</process>

<success_criteria>
- [ ] PR comments fetched via gh CLI
- [ ] Bot/noise comments filtered automatically  
- [ ] Each substantive comment presented for user triage
- [ ] User classified each as keep/skip/disagree
- [ ] Kept comments saved to ticket state file with category
- [ ] Disagreed comments saved with reasoning
- [ ] Event log entry added
- [ ] No automatic pattern extraction — that's /learn's job
</success_criteria>
