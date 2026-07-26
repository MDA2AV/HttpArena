# ServiceStack

One framework to power them all. Write your HTTP APIs once and take advantage of end to end typed integrations for all popular Web, Mobile and Desktop platforms.

## Stack

- **Language:** C# / .NET 10
- **Framework:** ServiceStack
- **Engine:** ServiceStack

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/baseline2` | GET | Sums query parameter values (HTTP/2 variant) |
| `/json` | GET | Processes 50-item dataset, serializes JSON |
| `/compression` | GET | Gzip-compressed large JSON response |
| `/upload` | POST | Receives 1 MB body, returns byte count |
| `/static/{filename}` | GET | Serves preloaded static files with MIME types |

## Notes

- Self-contained single-file deployment
