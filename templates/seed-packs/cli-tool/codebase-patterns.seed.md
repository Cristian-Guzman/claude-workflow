### [Pattern]: Errors to stderr, results to stdout — never mixed
- **Rule**: Diagnostics, progress and errors go to stderr; only the result the caller pipes goes to stdout.
- **Why**: Mixed streams break every `tool | jq` and every script that captures the output.
_Source: seed-pack:cli-tool_

### [Pattern]: Every flag has a help string and a long form
- **Rule**: Each flag gets `--long-form` plus a help line; a short `-f` only when it is typed often.
- **Why**: `--help` is the documentation most users will ever read.
_Source: seed-pack:cli-tool_

### [Pattern]: Exit codes are documented; non-zero on every non-success path
- **Rule**: The README/`--help` lists each exit code and its meaning; partial success is still non-zero unless explicitly documented.
- **Why**: Scripts branch on the exit code; an undocumented 0-on-failure is a silent data loss waiting to happen.
_Source: seed-pack:cli-tool_

### [Pattern]: `--dry-run` for anything that writes
- **Rule**: Every command that changes files or remote state accepts `--dry-run` and prints exactly what it would change.
- **Why**: Users learn a destructive tool by running it; dry-run makes that safe.
_Source: seed-pack:cli-tool_

### [Pattern]: Machine-readable output is a separate mode
- **Rule**: Offer `--json` (or similar) with a stable schema; keep the human output free to change.
- **Why**: Scripts parse the human text otherwise, and every wording change breaks them.
_Source: seed-pack:cli-tool_

### [Checklist]: Simplify smells /verify looks for in this stack
- Unused imports and dead branches
- Printing to stdout where stderr is correct
- Goroutine / async task without cancellation
- Bare `panic()` / `unwrap()` in non-test code
_Source: seed-pack:cli-tool_
