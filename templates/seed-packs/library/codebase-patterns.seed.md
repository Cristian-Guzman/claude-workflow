### [Pattern]: Public API changes require a changelog entry and a semver bump
- **Rule**: Any change to an exported name, signature or default lands with a CHANGELOG line and the matching patch/minor/major bump.
- **Why**: Consumers read the changelog, not the diff; an unversioned breaking change is a support incident.
_Source: seed-pack:library_

### [Pattern]: No process-level state at import time
- **Rule**: Importing the library mutates nothing: no env reads with side effects, no signal handlers, no stdout, no global registration.
- **Why**: Import-time effects break in the consumer's test runner first and are impossible to opt out of.
_Source: seed-pack:library_

### [Pattern]: Every public function has a doc comment with one usage example
- **Rule**: The example is the minimum call that does something useful; it compiles (see the testing seed).
- **Why**: The example is what gets copied; a signature alone is guessed at.
_Source: seed-pack:library_

### [Pattern]: Dependencies minimal and declared as ranges; host frameworks as peers
- **Rule**: Depend on as little as possible; declare the host framework (if any) as a peer/optional dependency, never pinned.
- **Why**: A pinned framework version in a library forces every consumer onto it.
_Source: seed-pack:library_

### [Gotcha]: Deprecate before removing
- **Rule**: Removing a public name takes two releases: a minor that warns, then a major that removes.
- **Why**: Consumers upgrade minors automatically; a removal there is a breaking change wearing a minor's number.
_Source: seed-pack:library_

### [Checklist]: Simplify smells /verify looks for in this stack
- Unused exports
- Stdout pollution in library code
- Bare `panic()` / `unwrap()` in non-test code
- Goroutine / async task without cancellation
_Source: seed-pack:library_
