<!--
  pr-template.md — PR description skeleton for this repo.
  Read by /pr, which fills the placeholders from the current branch's changes
  and the ticket's acceptance criteria, then outputs the raw markdown.
  Seed it manually at install (adjust sections + tracker URL to your project);
  /learn may grow it over time as your team's PR conventions evolve.
-->
// `/pr` creates the PR end-to-end: after CI is green, commit + push + `gh pr create --assignee "@me"` (invoking /pr is the authorization). ALSO output this markdown UNFORMATTED (raw, not rendered by Claude Code) plus a one-line commit message, so the user can copy them.

## 📋 Summary

[Brief description of what this PR does]

## 🎯 Ticket

<!-- EXAMPLE — replace with your tracker's URL pattern -->
[PROJ-123](https://your-tracker.example.com/browse/PROJ-123)

## ✨ Key Changes

### [Feature/Section Name] (AC#)
- [Change description]
- [Change description]

### Shared Components
- [Component name] - [Description]

## 🧪 Tests Added

- [Test category/file description]
- [Test category/file description]

## ✅ Definition of Done

- [ ] [AC1 description]
- [ ] [AC2 description]
- [ ] Unit tests added and passing
- [ ] E2E tests added (if applicable)

## 📸 Evidence

<!-- Screenshots comparing design vs implementation. Include for any UI changes. -->

| Design | Implementation |
|--------|----------------|
| ![Design](url) | ![Implementation](url) |

<!-- For non-UI changes, remove this section. -->

## 🧪 Testing Instructions

1. **[Test Scenario Name]**
   - [Step 1]
   - [Step 2]
   - Verify [expected result]

2. **[Test Scenario Name]**
   - [Step 1]
   - [Step 2]
   - Verify [expected result]
