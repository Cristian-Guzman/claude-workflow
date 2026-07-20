# Lessons from the field

Six months of daily use produced two kinds of knowledge. The mechanical rules went
into the commands themselves — branch guards, verification gates, checklists. This
file holds the other kind: the judgment calls. Ways of working that made the
human + Claude pairing effective, written down so they don't have to be relearned
one incident at a time.

They're phrased as instructions to the AI, but most cut both ways.

## Evidence beats theory

- **Verify ground truth before conceding.** When the human pushes back on a claim,
  don't immediately fold — run the cheap check first (one command: the deployed
  image tag, the hostname, the merge-base), then hold one evidence-backed position.
  Whipsawing between positions on pushback alone erodes trust in both directions.
- **Runtime evidence first for live-system bugs.** One log line from the real
  system beats a week of code-reading theories. Ask early for read-only access to
  logs and data stores; verify the bug mechanism against the live system before
  building a reproduction of what you *inferred* the bug to be.
- **Merged is not deployed.** QA tests the running environment. A fix that's merged
  but not deployed is invisible to them — check what's actually running (pod image,
  build artifact) before concluding a fix "didn't work".
- **Verify a subagent's claim before relaying it.** If a delegated investigation
  cites `file:line`, read that file and line yourself before repeating the claim.
  Same for external documents — re-fetch the cited source before flipping a verdict
  because someone paraphrased it.
- **Never pipe a CI gate through `tail` or `head`.** Truncating output masks
  failures and turns a red build green in your eyes only. Run it unpiped, or
  redirect to a file and check the exit code.
- **Check commit content after history surgery.** A squash via `reset --soft`
  captures the index, not the working tree. After any squash or amend, `git status`
  must be empty — otherwise you may have just shipped the wrong content.

## Scope is a promise

- **Fix every surface the spec names.** If the ticket says v1 and v2, or all N
  components, delivering one and staying silent about the rest is a failure mode
  that survives CI and dies in QA. Descope only out loud.
- **Copy only what the acceptance criteria name.** "Make X match reference Y" means
  the named properties — Y's decorative extras (accent bars, tints) are out of
  scope. Flag them; don't auto-copy them.
- **Verify before removing shipped behavior.** Making a control read-only or
  deleting an affordance can silently undo a teammate's feature that shipped last
  sprint. Tests pass, CI is green, QA bounces it. Check `git log` for who built
  what you're about to change.
- **Small asks get small changes.** A UI nudge is a nudge — don't rebuild the
  component. And never change typography or styling the spec didn't name; check
  `git diff` for accidental drift before claiming you didn't.
- **A ticket's layer is part of its scope.** A UI-only ticket doesn't grow feature
  flags, API clients, or backend changes on the way — even when they'd be "easy".

## Communication that survives contact

- **Don't re-deliberate after the human picks.** Present options once, with a
  recommendation. Once they choose, execute — re-opening the decision reads as
  not listening.
- **Ambiguous visual feedback: name the two elements first.** "Fix the padding"
  from a screenshot is ambiguous. Restate it — "the gap between the icon and the
  label" — and diff current-vs-expected element by element *before* editing.
  Guessing twice costs more than asking once.
- **Investigation delivers findings, not commits.** When asked to debug or assess,
  the deliverable is root cause + options. Don't branch, edit, or implement until
  the human explicitly says to — even if the fix seems obvious.
- **Report outcomes faithfully.** Failing tests get reported with their output;
  skipped steps get named as skipped. "Done" means verified, not hoped.

## Git discipline

- **Branch before the first edit.** Never work on a base branch — enforce it with
  a hook (see `guard-base-branch.sh`), because the rule you remember 99 times
  fails on the 100th.
- **A merged PR means fix-forward.** Once a PR merges, follow-up fixes go on a
  fresh branch as a new PR — never pushed onto the old one. Check PR state before
  every follow-up push.
- **Dirty tree? Ask before switching branches.** `git status --porcelain` first;
  unstaged work and a branch switch is how changes land on the wrong branch.
- **One PR per ticket unless asked otherwise.** Don't volunteer to split work
  across PRs; it multiplies review overhead without being requested.
- **Each pipeline step runs discretely.** Clarify, implement, verify, PR — run one,
  stop, let the human pace the next. Auto-chaining removes the checkpoints that
  catch mistakes while they're still cheap.

## Design fidelity

- **Fidelity must survive live data.** A pixel-perfect match against mock data
  breaks on the first empty list, overflowing string, or mixed content shape.
  QA with real data before calling it done.
- **Match the visual target, don't chase pixel-perfection.** Ship visibly-close,
  then iterate on QA feedback with small commits — many micro-commits per review
  round beat one big speculative rewrite.
- **Controls live at the scope they affect.** A selector that changes a modal's
  action belongs inside the modal, not on the page behind it.

## The learning loop itself

- **Patterns need a second occurrence.** One incident is an anecdote; two is a
  pattern. Resist writing a rule after every event or the pattern files bloat
  into noise nobody reads.
- **Don't extract lessons from unconfirmed fixes.** If QA hasn't signed off, the
  "lesson" might be a description of a bug you haven't found yet. Park the
  retrospective until the fix is confirmed.
- **Distill process, not code samples.** The durable output of a retrospective is
  "next time, do X first" — how work flows here — not another pasted code snippet.
- **Right-size the ceremony to the task.** Classify the tier first: a trivial fix
  skips the investigation fan-out entirely. Heavy process on light work is how
  workflows get abandoned.
