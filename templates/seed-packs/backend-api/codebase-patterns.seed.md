### [Pattern]: Parameterized queries only
- **Rule**: No string-concatenated SQL anywhere, including log statements and migrations.
- **Why**: Injection is the obvious reason; the quieter one is that concatenated SQL defeats the query planner's cache.
_Source: seed-pack:backend-api_

### [Pattern]: Every handler takes a context and respects cancellation
- **Rule**: Handlers and the services they call accept the request context and stop work when it is cancelled.
- **Why**: A client that gave up still consumes the worker and the DB connection otherwise.
_Source: seed-pack:backend-api_

### [Pattern]: Errors carry the operation name
- **Rule**: Wrap errors with the operation (`fetch order %d: %w`); never a bare `failed` / `error occurred`.
- **Why**: The log line is read without the stack; an unnamed error is unactionable.
_Source: seed-pack:backend-api_

### [Pattern]: New endpoints update the API spec in the same PR
- **Rule**: The OpenAPI / schema file changes in the commit that adds or changes the endpoint; the client types regenerate from it.
- **Why**: A spec that lags the code is a contract nobody can trust, and the frontend implements the guess.
_Source: seed-pack:backend-api_

### [Pattern]: Explicit transaction boundaries on multi-write operations
- **Rule**: Any operation that writes more than one row/table runs inside a transaction with explicit commit and rollback paths.
- **Why**: Implicit rollback-on-defer-only leaves half-written state on the paths nobody tested.
_Source: seed-pack:backend-api_

### [Pattern]: Validate at the trust boundary, trust internal callers
- **Rule**: Request handlers validate input shape and ranges once; internal services assume validated input and do not re-check.
- **Why**: Re-validation at every layer hides where the real boundary is and triples the error-handling surface.
_Source: seed-pack:backend-api_

### [Gotcha]: A toolchain bump cascades to the build image and the coverage toolchain
- **Rule**: When bumping the language/runtime version, move the CI build image and the coverage/lint tool versions in the same change.
- **Why**: The lockstep is invisible until CI fails on a tool that does not understand the new syntax.
_Source: seed-pack:backend-api_

### [Checklist]: Simplify smells /verify looks for in this stack
- Unused imports and dead branches
- String-concatenated SQL
- Goroutine / async task without cancellation
- Multi-write without a transaction boundary
- Bare `panic()` / `unwrap()` in non-test code
- Print statements left in
_Source: seed-pack:backend-api_
