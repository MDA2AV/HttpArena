# nestjs

NestJS 11 on the Express platform adapter, default configuration.

## Stack

- **Language:** TypeScript 5.9 on Node 26
- **Framework:** NestJS 11 (`@nestjs/platform-express`)
- **Build:** Two-stage, `node:26-trixie-slim` runtime

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/echo` | POST | Returns the request body back verbatim |

## Notes

- Controller with the Nest routing and `@Param` / `@Query` / `@Header` decorators
- Compression through the `compression` middleware, as the Nest docs recommend
- Body parsers are off and the POST endpoints read the raw stream, since they only sum or count what arrives
- The cluster module is used for multi-core scaling, one worker per available CPU
