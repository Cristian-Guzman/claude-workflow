### [Testing]: Selector priority: role > label > test id > text
- **Rule**: Use `getByRole` with a name first, then `getByLabel`, then `getByTestId`; `getByText` only for content assertions. Never `[class*=]`, tag chains or copy-coupled text where a test id exists.
- **Why**: Role and label selectors survive restyles and copy edits; class and copy selectors are the top drift sources.
_Source: seed-pack:testing/playwright_

### [Testing]: No `networkidle`, no blanket `waitForTimeout`
- **Rule**: Wait for the element (`expect(...).toBeVisible()`) or the response (`waitForResponse`) the step depends on.
- **Why**: `networkidle` never fires on pages with polling; fixed sleeps are either too short (flake) or too long (minutes per suite).
_Source: seed-pack:testing/playwright_

### [Testing]: Own your data
- **Rule**: Each spec creates what it reads (through the API or UI) and cleans up; never depend on seeded or leftover state.
- **Why**: Shared state makes specs order-dependent and makes parallel workers fail each other.
_Source: seed-pack:testing/playwright_

### [Testing]: A skip needs a reason key
- **Rule**: `test.skip` / `test.fixme` / `test.fail` carry `BUG <KEY>-n` or `FLAKY FL-n` in the reason; a bare skip is a false-green hiding drift.
- **Why**: Unkeyed skips are never revisited; the suite reports green while coverage quietly shrinks.
_Source: seed-pack:testing/playwright_

### [Testing]: Pre-merge runs target the branch's local server
- **Rule**: Point `baseURL` at the locally running branch for pre-merge runs; the deployed environment is for post-deploy checks only.
- **Why**: Running pre-merge against the deployed env tests yesterday's code and can only flag, never verify.
_Source: seed-pack:testing/playwright_

### [Testing]: Search before you click on large lists
- **Rule**: On paginated or long lists, filter/search to the target item first; never assume list position or scroll until visible.
- **Why**: Fixture growth moves items off the first page and turns a stable spec into a data-scale failure.
_Source: seed-pack:testing/playwright_
