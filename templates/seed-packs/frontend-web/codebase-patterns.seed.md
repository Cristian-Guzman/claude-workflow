### [Pattern]: Design tokens over hardcoded values
- **Rule**: No literal colors, spacings or font sizes in components — use the design-system tokens / CSS variables.
- **Why**: A hardcoded hex survives a theme change and a dark mode as a visible defect.
_Source: seed-pack:frontend-web_

### [Pattern]: Components render; the route or a hook fetches
- **Rule**: Data loading lives in the route/page or a dedicated hook; a component receives data and callbacks as props.
- **Why**: Fetching inside components couples them to a backend shape and makes them untestable without a network mock.
_Source: seed-pack:frontend-web_

### [Pattern]: Feature-local first, promote on the second consumer
- **Rule**: New UI lives in the feature module that renders it; move to the shared layer only when a second feature uses it.
- **Why**: Shared code accretes an implicit API that is expensive to change; premature sharing is the common over-engineering here.
_Source: seed-pack:frontend-web_

### [Pattern]: Keep the component library; do not swap for native controls
- **Rule**: When a design-system component exists, use it even if a native element would be shorter — match the visual target, then iterate.
- **Why**: A native control cannot be styled to the target or verified for a11y/i18n; the minimalism ladder's rung 3 is for logic, not UI.
_Source: seed-pack:frontend-web_

### [Gotcha]: A flex chain needs `min-height: 0` on every intermediate child to scroll
- **Rule**: Any flex child that must shrink to let a descendant scroll gets `min-height: 0` (or `min-width: 0` horizontally).
- **Why**: The default `min-height: auto` makes the child grow to its content; the scroll container never gets a bounded height.
_Source: seed-pack:frontend-web_

### [Gotcha]: Overflow clipping hides popovers and portals
- **Rule**: A parent with `overflow: hidden` clips anything positioned inside it; portal the floating element or position it `fixed`.
- **Why**: The popover 'does not open' symptom is usually clipping, not state — check the ancestor chain first.
_Source: seed-pack:frontend-web_

### [Gotcha]: `height: calc()` on a flex child fights the flex algorithm
- **Rule**: Size flex children with `flex-basis` / `flex: 1 1 0` and `min-height`, not a computed height.
- **Why**: Flex recomputes the main-axis size; a fixed `calc()` height either overflows or leaves a gap on every breakpoint.
_Source: seed-pack:frontend-web_

### [Checklist]: Simplify smells /verify looks for in this stack
- Unused imports and dead branches
- Inline styles where a token exists
- Native HTML where a design-system component exists
- `console.log` left in
- A component that fetches its own data
_Source: seed-pack:frontend-web_
