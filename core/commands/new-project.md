---
name: new-project
version: 0.12.1
description: Start a project from zero. Interviews you about what you want to make (platform, users, data, constraints, how it relates to what you already have), then writes a guide you READ AND DECIDE on — one recommended architecture with boring, proven technology on stable/LTS versions, two alternatives, and an explicit "not for this project" list. Writes .claude/project-brief.md; never scaffolds or installs anything. /build --from-brief takes it from there.
argument-hint: "[one line: what you want to make] [--here] [--sibling-of <existing-repo>]"
allowed-tools:
  - Read
  - Bash
  - Glob
  - Grep
  - Write
  - AskUserQuestion
---

> **Model floor: opus** — architecture guidance from an interview; the quality of the recommendation is the product. This is guidance, not a pin: the command inherits the session model. If you are a smaller model than the floor, say so in one line at the start and continue.

<objective>
Every other command assumes code to investigate. A new project has none: its source of truth is a
set of decisions nobody has written down yet. `/new-project` gets them written down. It asks what
you want to make, in plain terms, and turns the answers into a short guide — recommended
architecture, stack with a versions policy, repo layout, testing strategy, deploy path, and a
decisions table — that you read and settle. It does not scaffold. `/build --from-brief` scaffolds
from the settled brief, and `/bootstrap` configures the workflow's basics from it.
</objective>

<principles>
1. **Boring technology, stable versions.** Recommend what has a track record for this kind of
   product and a long-support channel. Pin to LTS / the stable channel, never `latest`, `next`,
   `canary` or a major released this quarter. Say which version and why.
2. **One recommendation, two alternatives, and a "not for this project" list.** Three options max
   per decision. The weird idea gets named and excluded with a reason, so it does not come back.
3. **Fit the size of the thing.** A solo app does not get microservices, an event bus, or a
   platform team's CI. Good architecture here means clear boundaries you can keep by hand.
4. **Decisions are the user's.** The guide proposes; the decisions table records what they chose.
   Nothing is final until a row has a choice. Ask one question per open row, never a wall.
5. **Nothing is created but the brief.** No `npm create`, no `git init`, no files beyond
   `.claude/project-brief.md`. Scaffolding is `/build`'s job, from a settled brief.
</principles>

<process>

## 0. Where does this project live

- `--here`: the current directory is the project (it must be empty or near-empty: no package
  manifest, fewer than 3 commits). Otherwise `WORKSPACE_ROOT` is a multi-repo workspace and the new
  project will be a sibling directory; the brief says which name.
- `--sibling-of <repo>` (or the one-liner mentions an existing app): read that repo's `CLAUDE.md`
  and repo profile first. The first architecture question becomes "share or separate" — backend,
  auth, data model, design system — and the guide must answer it explicitly with criteria.
- If `.claude/project-brief.md` already exists: show its decisions table and ask "revise or start
  over" before anything else.

## 1. Interview — three rounds, never more

Round 1, the shape (one AskUserQuestion with multi-select where it fits):
- **What is it, in one paragraph** — if `$ARGUMENTS` gave the one-liner, read it back and ask for
  the paragraph.
- **Platform**: web · mobile (iOS / Android / both) · desktop · API / service · CLI · library.
  Multi-select. For mobile and desktop, ask "native, or web tech packaged?" as the follow-up.
- **Who uses it, how many, how often** — solo / a team / the public; tens / thousands / more.

Round 2, the substance:
- **Data**: where it lives (local only · one database · an existing backend), how sensitive it is,
  whether it must work offline.
- **Auth**: none · single user · accounts · an existing identity provider.
- **Integrations** the product cannot exist without (payments, bank APIs, email, maps…).
- **Relation to what you already have** — reuse of a backend, a design system, a data model.

Round 3, the constraints:
- **Team and time**: who builds it, how many hours a week, when it must exist.
- **Hosting and budget**: free tier · a VPS · a cloud account · the user's own machine.
- **Non-goals** — what it must NOT become (ask explicitly; this is where scope dies quietly).
- **Hard preferences**: languages or tools the user wants or refuses. Respect refusals; argue with
  preferences only when they conflict with principle 1, and say so in the guide.

Stop asking when the three rounds are answered. Unknowns become rows in "Open questions".

## 2. Check the stable channels before recommending versions

For each runtime and framework you are about to recommend, find the current stable / LTS line
and name it in the guide. Mechanics, in order: the tool's own channel (`node --version` and the
Node release schedule; `npm view <pkg> dist-tags` for the `latest` vs `lts` vs `next` tags;
`python3 --version`; `go version`); web lookup when available; otherwise your knowledge, marked
"verify before scaffolding". A tag named `next`, `canary`, `beta`, `rc` is never recommended.

## 3. Write the guide

`.claude/project-brief.md`, in this order, short sections, no filler:

```markdown
# Project brief — {name}

## Summary
{one paragraph, the user's words tightened}

## Platform
{what was chosen and what that implies: packaging, stores, offline, update path}

## Relation to existing projects
{share vs separate, per concern: backend · auth · data · design system — with the reason}

## Architecture — recommended
{the shape in five lines: layers / boundaries / where state lives / how the UI talks to data}
Why this one: {two sentences}

### Alternatives considered
| Option | When it would win | Why not here |

### Not for this project
- {the idea that came up or that models tend to propose, and why it is excluded}

## Stack and versions policy
| Layer | Choice | Version line | Why |
Rule: LTS / stable channel only; pin via `.nvmrc` / lockfile / toolchain file; upgrades are a
deliberate task, never a side effect.

## Repo layout
{tree, 10–20 lines, with one-line purposes — this becomes the first codebase-patterns entry}

## Testing strategy
| Tier | Tool | What it proves | Runs where |

## CI and deploy
{the minimal pipeline for this size; where it deploys; what "done" means for a release}

## Data and auth
{model sketch, storage, migrations, backups, how auth attaches}

## Risks
- {three at most, each with the early signal that it is happening}

## Decisions
| # | Decision | Recommended | Alternatives | Your choice |
|---|---|---|---|---|
| 1 | … | … | … | [ ] |

## Open questions
- {anything the interview left unknown}
```

## 4. You read, you decide

Show the guide. Then, for each decisions row still `[ ]`, one AskUserQuestion with the recommended
option first. Write the choice into the row. A choice that conflicts with principle 1 is recorded
with a one-line note, not refused — it is the user's project.

## 5. Persist and hand off

Write `.claude/project-brief.md` (create `.claude/` if needed; nothing else is created). Then stop:

> "Brief written to `.claude/project-brief.md` — {n} decisions settled, {m} open. Next: re-run
> `install.sh <dir> --role dev --stack <flavor>` with the flavor the brief chose (it appends the seed
> patterns for it; the workflow itself is already installed, or this command could not have run), then
> `/build --from-brief` to scaffold and build the first feature, then `/bootstrap` to configure the
> workflow from what now exists."

</process>

<guidelines>
- Never scaffold, install, `git init`, or touch any file but the brief.
- "Additional app next to an existing one" is the common case: answer share-vs-separate per
  concern, and prefer one repo per deployable unit unless the user already runs a monorepo.
- Recommend the framework's own generator for scaffolding (named in the brief) so `/build` does
  not hand-roll a project structure.
- Versions: name the line (e.g. "Node 22 LTS", "the `lts` dist-tag"), not a point release.
- Related: `/build --from-brief` (scaffolds and builds), `/bootstrap` (configures the workflow
  basics from the brief on a sparse repo), `install.sh --stack` (seed patterns for the flavor).
</guidelines>

<success_criteria>
- [ ] Three interview rounds at most; unknowns landed in "Open questions", not guessed.
- [ ] Every recommended runtime/framework names its stable or LTS line; no `latest`/`next`/`canary`.
- [ ] One recommendation, ≤2 alternatives, and a "Not for this project" list per architecture decision.
- [ ] Every decisions row has a choice or is listed as open; the user's refusals were respected.
- [ ] Only `.claude/project-brief.md` was written.
</success_criteria>
