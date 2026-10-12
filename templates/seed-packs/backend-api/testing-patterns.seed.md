### [Testing]: Handler tests go through the router
- **Rule**: Exercise handlers via the HTTP test server (`httptest`, `supertest`, test client) so middleware, routing and serialization run.
- **Why**: Calling the handler function directly skips exactly the wiring that breaks in production.
_Source: seed-pack:backend-api_

### [Testing]: Table-driven tests for pure logic
- **Rule**: One table of (input, expected) cases per function; one row per branch; names that read as the rule.
- **Why**: Tables make the missing case visible; copy-pasted test functions hide it.
_Source: seed-pack:backend-api_

### [Testing]: Integration tests separated from unit tests
- **Rule**: Tests that need a database or network live behind a build tag, a directory, or a separate script — never mixed into the unit run.
- **Why**: A unit suite that sometimes needs a database is a suite nobody runs locally.
_Source: seed-pack:backend-api_

### [Testing]: Mock the repository interface, never the driver
- **Rule**: Services depend on a repository interface; tests substitute an in-memory implementation. The driver is tested once, in the integration suite.
- **Why**: Driver-level mocks encode SQL strings into tests and break on every harmless query change.
_Source: seed-pack:backend-api_

### [Testing]: Provider tests assert delegation, return value and error propagation
- **Rule**: One `describe` per method: (1) the dependency was called with the right args, (2) the return value matches, (3) errors propagate unchanged.
- **Why**: Those three are the whole contract of a thin provider; anything else tests the mock.
_Source: seed-pack:backend-api_
