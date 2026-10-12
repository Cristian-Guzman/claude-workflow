### [Testing]: `supertest` against the app instance, not a listening server
- **Rule**: Import the app (not `server.listen`) and run requests through `supertest`; mock the service layer.
- **Why**: Binding a port makes tests order-dependent and flaky in parallel; the app instance is enough.
_Source: seed-pack:backend-api/express_

### [Testing]: Auth wiring is tested once per router
- **Rule**: One test per router asserts an unauthenticated request gets 401; per-handler tests assume an authenticated context.
- **Why**: Repeating the auth assertion in every handler test triples the suite without adding coverage.
_Source: seed-pack:backend-api/express_
