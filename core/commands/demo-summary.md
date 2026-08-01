---
name: demo-summary
version: 0.6.0
description: Build a sprint-demo runbook from your delivered work — turns "what I shipped" into a user-journey narrative with per-beat talking points, a pre-demo setup checklist, live-demo risk notes, and an ownership guard that flags adjacent work owned by teammates so you never present their ticket as yours.
argument-hint: "[--sprint | --week | --days N] [--repo NAME] [--audience team|stakeholders] [--artifact]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Agent
  - Write
  - AskUserQuestion
  - Artifact
---

<objective>
`/status` is a raw dashboard of in-flight work. `/retro` is a process retrospective (what to do better). `/demo-summary` is **audience-facing**: it turns the work you delivered this sprint into *how you present it* — a tight runbook you read from during a demo.

It exists because two things sink a demo:
1. **You accidentally demo a teammate's ticket** (e.g. you built Export, the natural round-trip is their Import — demoing it steps on their slot). The command's **ownership guard** detects adjacent work owned by someone else and recommends a handoff instead.
2. **The live demo breaks** because a feature flag was off, an account wasn't in the right state, or a sideload-only surface couldn't be driven. The **pre-demo setup checklist** front-loads exactly what to stage.

Default audience is a **team demo** (everyone demos their own work): plain peer language, no marketing spin, assume shared context, keep it tight. Output: a runbook printed to the chat, optionally a keep-open HTML page and a saved markdown file.
</objective>

<process>

## 0. Parse arguments & resolve scope

**Scope is sprint-membership first; a calendar window is only a fallback.** A sprint demo is bounded by a *named Jira sprint*, not by "the last N days." A rolling window pulls in prior-sprint work that merged late and misses next-sprint work that merged early — this is the failure mode that has produced bloated, wrong-scoped first passes.

- `--sprint` (default) → the **active Jira sprint** (`sprint in openSprints()`). `--sprint "PROJ.2026.NN"` (use your team's sprint naming) → that named sprint.
- `--days N` / `--week` → **calendar fallback only** (Jira unreachable, or the user explicitly wants a raw window). Resolve `WINDOW_START` with `date -v-Nd` (BSD; never `date -d`).
- `--repo NAME` — limit to one repo.
- `--audience team` (default) | `stakeholders` — controls tone (see Step 5).
- `--artifact` — also render the keep-open HTML runbook page.

Resolve `TODAY` and `AUTHOR` (`git config user.email`, or `@me` for `gh`; `currentUser()` for Jira).

If the user pasted a demo roster/email (who's demoing what), capture it — it makes Step 3's ownership guard far sharper.

## 1. Gather YOUR delivered work (parallel)

**Primary — Jira sprint membership (the source of truth for "what's in this sprint"):**

```
jira issue list -p PROJ --jql 'assignee = currentUser() AND sprint in openSprints()' \
  --plain --columns KEY,TYPE,STATUS,SUMMARY
```

(or `sprint = "PROJ.2026.NN"` for a named sprint). This is what **defines** the candidate set — not a date window.

Fire these together to enrich + confirm delivery:

- **Merge status — scope by MERGE DATE, never state `updated`:** `gh pr list --author @me --state merged --json number,title,url,mergedAt,mergeCommit` per repo; match PRs to the Jira keys by branch/title. ⚠️ A ticket's state-file `updated` is a `/learn` bookkeeping stamp — it does **not** mean the work merged this sprint (this is exactly what mis-scoped PROJ-6505: merged Jun 17, `updated` Jun 23). Trust `mergedAt` + sprint membership.
- **State index (enrichment only):** read `.claude/state/index.json` for branch / PR# / status per key — but membership comes from Jira, not from `updated >= WINDOW_START`.
- **Calendar fallback (no Jira only):** per repo, `git -C <repo> log --all --author "<AUTHOR>" --since "<WINDOW_START>" --pretty=format:"%ad | %an | %s" --date=short`.

Collect candidates: `{ticketId, repo, title, pr, mergedAt, jiraStatus, inSprint}`. A ticket that merged **outside** the sprint boundary (adjacent sprint) is flagged `borderline`, not silently dropped or kept.

## 2. Filter to demo-worthy — drop the noise (but say what you dropped)

Exclude (and list them in one line at the end — **never silently truncate**, per the no-silent-caps rule):
- Dependabot / security bumps (`bump`, advisory, dep version PRs)
- Test-only or E2E work (`test(...)`, spec repair, flake fixes)
- Dead-code / cleanup refactors with no user-visible change
- Pure chores / config

Keep anything with a **user-visible surface** (feat, user-facing fix). When unsure, keep it and flag it as borderline.

## 3. Ownership guard — flag teammate-adjacent work ⚠️ (the guardrail)

For each kept ticket, find its natural demo counterpart and who owns it:
- Features pair up: **export↔import, create↔consume, FE↔BFF, list↔detail, admin-write↔user-read**. Look for sibling tickets in the same epic, or commits touching the same screen/endpoint.
- Check authorship: `git -C <repo> log -1 --format="%an <%ae>" <commit>` on the counterpart, and cross-reference the roster if provided.
- If the counterpart was authored by **someone else**, mark `pairsWith: PROJ-YYYY (owner: <name>)`.

The runbook will recommend a **handoff** for those, not a demo. **Never present a teammate's ticket as your own.**

## 3.5 Confirm scope + order with the user (checkpoint — BEFORE fanning out)

Do **not** build demo cards yet. Building the full runbook before scope is confirmed means every correction is a full re-cut (this is what happened when the first pass shipped 11 tickets and got re-scoped twice, then re-ordered). First show a cheap, scannable summary and get the user's lineup:

- **In sprint** — demo-worthy tickets, with a *proposed* demo order.
- **Borderline** — merged adjacent-sprint, or in-sprint but not obviously user-visible (E2E, cleanup) — ask whether to include.
- **Dropped** — Dependabot / test-only / chores (one line, per no-silent-caps).

**The user's chosen order and inclusion always override the sprint filter and ownership guard** — those are inputs, not the verdict. The user knows what they're presenting: they may demo next-sprint work early, or skip something that technically qualifies. Wait for confirmation/edits, then fan out on the **confirmed set only**.

## 4. Fan out — one reader per confirmed ticket → demo card

Spawn parallel Agents (`codebase-investigator` or `general-purpose`), one per confirmed ticket. Each reads, in order: the ticket state file → `{id}-clarify.md` → the git diff for its commits → optionally `jira issue view {id}` (CLI fallback; don't block). 

**Verify before relaying:** a reader asserting how code behaves must cite `file:line`; do not relay a sub-agent's "it works / it's gated / it round-trips" claim unread (see `feedback_verify_subagent_code_claims`). The setup checklist depends on these being right.

Each returns a **demo card**:
- `demoTitle` — audience-facing name, not the Jira title
- `whatChanged` — 1–2 sentences, plain (peer-level for a team audience)
- `demoSurface` — app / page / URL, or sideloaded add-in + nav path
- `howToDemo` — concrete click-path
- `status` — merged + PR#, Jira state, deployed env
- `caveats` — feature flags (+ keys, flat-rollout vs companyId-targeted), mock vs real data, required account/company state, sideload-only, backend deps not yet deployed
- `talkingPoint` — one sentence (plain for team; value-framed for stakeholders)
- `owner`, `pairsWith`

## 5. Synthesize the runbook

**Tone by audience:**
- `team` (default) — plain, peer-level, zero marketing. Assume shared context, minimize catch-up, keep it tight. Add a "short on time → lead with Beats X & Y" line.
- `stakeholders` — value/narrative framing, business "why it matters."

**Sections:**
- **The story** — one narrative thread. If the work fits a user journey (discover → sign up → use → run out → buy → admin), order it that way; it reads far easier than a ticket list.
- **Demo order** — 5–7 beats, sequenced to tell the story. Merge tickets that live on the same screen into one beat. Each beat: surface · tickets · click-path · one talking point.
- **Pre-demo setup checklist** — pulled from every card's `caveats`: which flags ON (keys; flat-rollout vs targeted), which test company/account in which state, sideload state for add-ins, tabs/URLs to pre-open, deploy confirmations. This is the part that stops the live demo from breaking.
- **Don't demo live** — mock data, sideload-only fragility, unmerged cosmetics, backend not deployed → with a safe fallback (screenshot / describe).
- **Teammate handoffs** — every `pairsWith`: "X is yours; the other half PROJ-YYYY is <owner>'s — hand off, don't demo it."
- **Backup table** — `ticket | demo title | status`, so anything cut for time can still be name-dropped.

## 6. Render & offer to save

- Print the full runbook to the chat.
- If `--artifact` (or offer it): write self-contained HTML to `$WORKSPACE_ROOT/.claude/demos/demo-{YYYY-MM-DD}.html` and publish via **Artifact** (favicon `🎬`, stable `<title>`) — a keep-open page to glance at during the demo.
- Ask before writing markdown: "Save to `.claude/demos/demo-{YYYY-MM-DD}.md`?" Write only if approved.

## 7. Standalone — no auto-chain

Per `feedback_run_commands_discretely`, this command runs by itself. Don't auto-trigger `/status`, `/retro`, etc.

</process>

<success_criteria>
- [ ] Scope resolved from **Jira sprint membership** (confirmed by merge date), not a rolling calendar window; audience resolved; AUTHOR scoped to the user (not the whole team)
- [ ] Candidate set gathered from Jira sprint + merged PRs (merge date, not state `updated`); adjacent-sprint items flagged `borderline`
- [ ] Noise filtered, with a one-line list of what was dropped
- [ ] Ownership guard ran — every kept ticket has an `owner`, and teammate-adjacent counterparts are flagged as handoffs, not demos
- [ ] **Scope + proposed order confirmed with the user BEFORE any cards were built**; user's lineup overrode the heuristics where they differed
- [ ] One demo card per confirmed ticket; behavior claims verified at file:line
- [ ] Runbook has story · demo order · setup checklist · don't-demo-live · handoffs · backup table
- [ ] Tone matches audience (plain for team, value-framed for stakeholders)
- [ ] Nothing written/published unless approved (markdown save asked; artifact on flag or offer)
</success_criteria>

## Related Commands
- Inputs: `/status` (in-flight dashboard), `/project-context` (team-ticket dossiers — sharpens the ownership guard), `.claude/tickets/*.md` state files.
- Sibling: `/retro` (process retrospective — what to improve, not what to present).
- New command → run `/bootstrap --check` once to register it in the hash ledger. Never commit the `.claude` system.
