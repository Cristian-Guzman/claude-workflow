### [Pattern]: The API contract is the source of truth
- **Rule**: Client types regenerate from the OpenAPI/schema file; nobody hand-edits the generated types or derives the spec from the client.
- **Why**: Two hand-maintained copies of one contract drift within a sprint.
_Source: seed-pack:fullstack-monorepo_

### [Pattern]: New endpoints land with a backend handler test and a frontend contract test
- **Rule**: The same PR that adds an endpoint adds the handler test and a client test pinned to the spec's response shape.
- **Why**: The contract is only proven when both sides are tested against the same shape.
_Source: seed-pack:fullstack-monorepo_

### [Gotcha]: A backend-live-but-no-gateway-route gap looks like a frontend bug
- **Rule**: When the client gets a 404/500, check each layer on the path (gateway route registered? proxy forwarding? backend deployed?) before debugging the client.
- **Why**: The symptom surfaces in the browser; the cause is usually a missing route one layer down.
_Source: seed-pack:fullstack-monorepo_

### [Checklist]: Simplify smells /verify looks for in this stack
- Both the frontend-web and backend-api smell lists apply
- A hand-written type that mirrors a generated one
- A client call to an endpoint absent from the spec
_Source: seed-pack:fullstack-monorepo_
