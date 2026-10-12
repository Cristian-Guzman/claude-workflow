### [Gotcha]: A server-side read on a static route is frozen at build time
- **Rule**: A flag or data read in a Server Component on a route with no dynamic trigger is prerendered once; force dynamic rendering or move the read. Reproduce with build + start, never with the dev server.
- **Why**: Static prerendering bakes the value into the HTML; the dev server re-renders per request and hides the freeze.
_Source: seed-pack:frontend-web/nextjs_

### [Pattern]: Server / client boundary is explicit
- **Rule**: Server-only modules (secrets, DB clients, server SDKs) are never imported into a client component; mark them server-only and keep the boundary in the file tree.
- **Why**: A single client import pulls a server module into the browser bundle or fails the build in a confusing place.
_Source: seed-pack:frontend-web/nextjs_

### [Gotcha]: CSS Modules + hot reload can lie about visual state
- **Rule**: When a style change does not appear, restart the dev server before tweaking values further; `:global()` selectors are the usual victim.
- **Why**: HMR misses some CSS-module and git-checkout changes; chasing a stale render costs rounds.
_Source: seed-pack:frontend-web/nextjs_

### [Pattern]: Version parallel surfaces at the route segment
- **Rule**: When two versions of a surface coexist, version at the route segment (`/v2/...`) with one source of truth per concern — not with branches inside components.
- **Why**: Route-level versioning keeps each tree independently deletable; in-component branches never die.
_Source: seed-pack:frontend-web/nextjs_
