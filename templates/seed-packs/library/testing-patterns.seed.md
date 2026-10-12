### [Testing]: Test the public surface only
- **Rule**: Tests import what a consumer imports; internals are covered through behavior, not by reaching into private modules.
- **Why**: Tests of internals freeze the implementation and break on every refactor that keeps the API intact.
_Source: seed-pack:library_

### [Testing]: The documented examples compile
- **Rule**: A test (type-level test file, example test, doctest) compiles or runs every usage example in the doc comments.
- **Why**: Examples that stop compiling are the first thing a consumer notices and the last thing CI does.
_Source: seed-pack:library_

### [Testing]: Pin the exported-names set
- **Rule**: One test asserts the set of public exports equals an explicit list; additions and removals are deliberate edits to that list.
- **Why**: An accidental export is a permanent API; an accidental removal is a breaking change nobody meant.
_Source: seed-pack:library_
