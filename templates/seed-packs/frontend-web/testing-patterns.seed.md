### [Testing]: New components ship with at least one render test
- **Rule**: Every new component gets a test that renders it with realistic props and asserts the visible result.
- **Why**: A render test catches the import/prop-shape breakages that type-checking misses at the boundary.
_Source: seed-pack:frontend-web_

### [Testing]: Query by role and label, not by class or DOM structure
- **Rule**: Prefer `getByRole` / `getByLabelText`; fall back to a test id; never query by class name or tag nesting.
- **Why**: Role queries survive refactors and double as an accessibility check; class queries break on every style change.
_Source: seed-pack:frontend-web_

### [Testing]: jsdom has no layout engine — assert the prop, not the computed style
- **Rule**: For layout-driving behavior (widths, positions, drawer sizes) assert the prop or class passed to the component, not `getComputedStyle`.
- **Why**: jsdom does not lay out; computed-style assertions pass vacuously or fail for the wrong reason.
_Source: seed-pack:frontend-web_

### [Testing]: Mock the data hook or module, not the fetch internals
- **Rule**: Mock at the module boundary the component imports (the hook or client module), not `fetch`/XHR.
- **Why**: Mocking the transport couples tests to the request shape; mocking the module tests the component's contract.
_Source: seed-pack:frontend-web_

### [Testing]: Every interactive state gets a test
- **Rule**: Empty, loading, error, disabled and overflowing-content states each get an assertion, not only the happy path.
- **Why**: The mock data shows the happy path; the states nobody enumerated are where QA rounds come from.
_Source: seed-pack:frontend-web_

### [Testing]: `aria-label` replaces the visible text as the accessible name
- **Rule**: When an element has an `aria-label`, role queries by name must use the label string, not the visible text.
- **Why**: The accessible name is the label; a query by visible text finds nothing and the test is rewritten wrongly to a class selector.
_Source: seed-pack:frontend-web_
