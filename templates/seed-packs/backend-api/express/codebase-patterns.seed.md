### [Pattern]: Router → controller → service; controllers stay thin
- **Rule**: Routers map paths to controllers; controllers parse/validate and call one service method; services hold the logic.
- **Why**: Logic in controllers cannot be reused by a job or a second transport and cannot be unit-tested without HTTP.
_Source: seed-pack:backend-api/express_

### [Pattern]: Async handlers are wrapped so rejections reach the error middleware
- **Rule**: Every async route handler goes through an async wrapper (or the framework's native async support); never a bare `async (req, res) =>`.
- **Why**: An unhandled rejection in a route is a hung request and a crashed process, not a 500.
_Source: seed-pack:backend-api/express_

### [Pattern]: One error middleware at the end; handlers throw typed errors
- **Rule**: Handlers throw an error class that carries status and code; the single error middleware maps it to the response. No inline `res.status(500)`.
- **Why**: Centralised mapping keeps the error contract consistent and makes it testable in one place.
_Source: seed-pack:backend-api/express_

### [Gotcha]: Middleware order is behavior
- **Rule**: Body parsers and auth are registered before routers; the 404 handler and the error middleware are registered last.
- **Why**: A router registered before the parser sees an empty body; an error handler registered early catches nothing.
_Source: seed-pack:backend-api/express_
