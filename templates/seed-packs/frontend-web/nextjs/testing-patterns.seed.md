### [Testing]: Mock server-only modules in jsdom; test Server Components as async functions
- **Rule**: Mock the server-only imports at the module level and call the async component to assert its returned tree.
- **Why**: jsdom cannot load server-only modules; the async component is a plain function and tests as one.
_Source: seed-pack:frontend-web/nextjs_

### [Testing]: A build-only directive has no runtime behavior — assert its source text
- **Rule**: For `force-dynamic` and similar route-segment config, read the file in the test and match the directive; there is nothing to render.
- **Why**: The directive changes the build, not the component; a render test cannot observe it.
_Source: seed-pack:frontend-web/nextjs_
