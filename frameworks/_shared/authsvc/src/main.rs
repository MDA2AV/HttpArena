// authsvc — shared edge-auth sidecar for the production-stack test.
//
// Verifies HMAC-SHA256 JWTs on every request. No caching — every call
// does real cryptographic work. The hot path is:
//
//   1. Read `Authorization: Bearer <token>` header
//   2. Split on "." → header.payload.signature
//   3. HMAC-SHA256(secret, header.payload) → compare with signature
//   4. Base64-decode payload → extract "sub" claim (user_id)
//   5. Return 200 + X-User-Id or 401
//
// No Redis, no DashMap, no caching. Pure CPU-bound auth verification
// on every single request. This is the "stateless JWT" model used by
// most modern API gateways — the token is self-contained and the
// verifier needs only the shared secret.
//
// The JWT secret is read from the JWT_SECRET env var (default:
// "httparena-bench-secret-do-not-use-in-production"). The same secret
// is used to pre-generate the benchmark token in data/jwt-token.txt.

use std::net::SocketAddr;

use axum::{
    extract::State,
    http::{HeaderMap, HeaderValue, StatusCode},
    response::IntoResponse,
    routing::get,
    Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use hmac::{Hmac, Mac};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone)]
struct AppState {
    secret: Vec<u8>,
}

#[tokio::main]
async fn main() {
    let secret = std::env::var("JWT_SECRET")
        .unwrap_or_else(|_| "httparena-bench-secret-do-not-use-in-production".into())
        .into_bytes();
    let listen_addr =
        std::env::var("AUTHSVC_LISTEN").unwrap_or_else(|_| "0.0.0.0:9090".into());

    let state = AppState { secret };

    let app = Router::new()
        .route("/_auth", get(auth_handler))
        .route("/_health", get(health_handler))
        .with_state(state);

    let addr: SocketAddr = listen_addr.parse().expect("invalid AUTHSVC_LISTEN");
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .unwrap_or_else(|e| panic!("bind {addr}: {e}"));

    eprintln!("authsvc listening on {addr} (JWT HMAC-SHA256)");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("server error");
}

// GET /_auth — verify JWT on every request. No caching.
//
// Expects: Authorization: Bearer <header>.<payload>.<signature>
// Payload must contain "sub" field with the user_id.
//
// HMAC-SHA256 verification: ~1 µs per token on modern CPUs.
// At 200K rps × 60% /api/* = ~120K verifications/sec. On 2 logical
// CPUs that's ~60K/core — well within HMAC-SHA256's throughput
// ceiling (~500K-1M verifications/core/sec depending on token size).
async fn auth_handler(State(state): State<AppState>, headers: HeaderMap) -> impl IntoResponse {
    // Extract Bearer token from Authorization header.
    let auth = headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    let token = match auth.strip_prefix("Bearer ") {
        Some(t) => t,
        None => return StatusCode::UNAUTHORIZED.into_response(),
    };

    // Split into header.payload.signature
    let parts: Vec<&str> = token.splitn(3, '.').collect();
    if parts.len() != 3 {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    let signed_content = &token[..parts[0].len() + 1 + parts[1].len()]; // "header.payload"
    let provided_sig = match URL_SAFE_NO_PAD.decode(parts[2]) {
        Ok(s) => s,
        Err(_) => return StatusCode::UNAUTHORIZED.into_response(),
    };

    // HMAC-SHA256 verify
    let mut mac =
        HmacSha256::new_from_slice(&state.secret).expect("HMAC accepts any key length");
    mac.update(signed_content.as_bytes());
    if mac.verify_slice(&provided_sig).is_err() {
        return StatusCode::UNAUTHORIZED.into_response();
    }

    // Decode payload and extract "sub" claim.
    // Minimal JSON parsing — we only need "sub":"<value>".
    let payload_bytes = match URL_SAFE_NO_PAD.decode(parts[1]) {
        Ok(b) => b,
        Err(_) => return StatusCode::UNAUTHORIZED.into_response(),
    };

    let payload = match std::str::from_utf8(&payload_bytes) {
        Ok(s) => s,
        Err(_) => return StatusCode::UNAUTHORIZED.into_response(),
    };

    // Find "sub": in the JSON. Avoid pulling in serde_json for a
    // single field extraction — this sidecar should be as tiny as
    // possible. The token format is controlled by our own generator
    // so we know the shape.
    let sub = extract_claim(payload, "sub");
    match sub {
        Some(user_id) => {
            let mut out = HeaderMap::new();
            if let Ok(v) = HeaderValue::from_str(user_id) {
                out.insert("x-user-id", v);
            }
            (StatusCode::OK, out, "").into_response()
        }
        None => StatusCode::UNAUTHORIZED.into_response(),
    }
}

// Extract a string or number claim value from a JSON object.
// Handles both "sub":"42" and "sub":42.
fn extract_claim<'a>(json: &'a str, key: &str) -> Option<&'a str> {
    let pattern = format!("\"{}\":", key);
    let start = json.find(&pattern)? + pattern.len();
    let rest = json[start..].trim_start();
    if rest.starts_with('"') {
        // String value: "sub":"42"
        let inner = &rest[1..];
        let end = inner.find('"')?;
        Some(&inner[..end])
    } else {
        // Number value: "sub":42
        let end = rest.find(|c: char| c == ',' || c == '}' || c == ' ')?;
        Some(&rest[..end])
    }
}

async fn health_handler() -> impl IntoResponse {
    StatusCode::OK
}

async fn shutdown_signal() {
    use tokio::signal::unix::{signal, SignalKind};
    let mut term = signal(SignalKind::terminate()).expect("listen SIGTERM");
    let mut int = signal(SignalKind::interrupt()).expect("listen SIGINT");
    tokio::select! {
        _ = term.recv() => {},
        _ = int.recv()  => {},
    }
}
