# CLAUDE.md

> Seeded by claude-workflow as a minimal starting point — replace every {placeholder},
> or run `/init` and merge the generated content into this structure. Every workflow
> command loads this file first; the better it is, the better every command performs.

## What this repo is

{One paragraph: what this product/service does, who consumes it, and where it sits
in the larger system (calls what, is called by what).}

## Stack

- Language / framework: {e.g. TypeScript + React 19 / Go 1.24 / Python 3.13}
- Package manager / build: {e.g. yarn 4 / go build / uv}

## Commands

- Install deps: `{...}`
- Dev server: `{...}` {(URL it serves on)}
- Lint: `{...}`
- Typecheck: `{...}`
- Tests: `{...}`
- Full CI gate — run before every push: `{...}`

## Conventions

- Base branch: `{main}` — feature branches: `feat|fix|chore/{TICKET-ID}-short-slug`
- {Code style the assistant must match: naming, error handling, comment policy, ...}
- {Where new code goes: feature-local vs shared, directory conventions}

## Gotchas

{Non-obvious things that waste time — flaky commands, env quirks, files that look
editable but aren't. Start empty; /learn grows this section from real tickets.}
