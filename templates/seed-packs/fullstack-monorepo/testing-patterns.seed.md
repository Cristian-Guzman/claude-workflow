### [Testing]: Contract tests pin the response shape at the gateway
- **Rule**: One contract test per endpoint asserts the gateway's response matches the spec; unit tests on either side mock the contract, not each other.
- **Why**: Mocking the other side's implementation tests an assumption; mocking the contract tests the agreement.
_Source: seed-pack:fullstack-monorepo_

### [Testing]: Enums and unions are re-derived from the spec with a set-equality test
- **Rule**: A test loads the spec file and asserts the code's enum set equals the spec's — a spec change fails the build, not a user flow.
- **Why**: Enums copied from a chat message or inferred from id prefixes are the recurring cross-repo defect class.
_Source: seed-pack:fullstack-monorepo_
