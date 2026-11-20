# Proa + Axum

Axum runs the HTTP server and handles routing and request extraction. Proa compiles the Fortunes HTML component. tokio-postgres queries PostgreSQL on every Fortunes request. The handler borrows message text from the returned rows, appends the runtime row, sorts by message byte order, and renders into one owned HTTP body. Proa escapes the message text as it writes the HTML.

The other opted-in profiles measure the Axum server and its Tokio runtime. Use the Fortunes profile to compare full database-to-HTML responses.
