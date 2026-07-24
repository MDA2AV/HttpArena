use crate::state::AppState;
use askama::filters::Escaper;
use deadpool_postgres::Pool;
use std::{fmt, sync::Arc};
use trillium::{Conn, KnownHeaderName, Status};
use trillium_askama::{AskamaConnExt, Template};

pub struct Fortune {
    pub id: i32,
    pub message: String,
}

#[derive(Template)]
#[template(path = "fortunes.html")]
struct FortunesTemplate {
    fortunes: Vec<Fortune>,
}

/// Auto-escaper used for the `.html` extension via `askama.toml`.
///
/// Askama 0.15's built-in `Html` escaper writes numeric entities (`&#60;`),
/// but the validator greps for the literal `&lt;script&gt;`. This emits
/// the named entities instead.
#[derive(Copy, Clone)]
pub struct NamedHtmlEscaper;

impl Escaper for NamedHtmlEscaper {
    fn write_escaped_str<W: fmt::Write>(&self, mut dest: W, s: &str) -> fmt::Result {
        let mut last = 0;
        for (i, b) in s.bytes().enumerate() {
            let replacement = match b {
                b'<' => "&lt;",
                b'>' => "&gt;",
                b'&' => "&amp;",
                b'"' => "&quot;",
                b'\'' => "&#39;",
                _ => continue,
            };
            dest.write_str(&s[last..i])?;
            dest.write_str(replacement)?;
            last = i + 1;
        }
        dest.write_str(&s[last..])
    }
}

pub async fn fortunes(conn: Conn) -> Conn {
    let state = Arc::clone(conn.shared_state::<Arc<AppState>>().expect("AppState set"));
    let Some(pool) = &state.pg else {
        return conn.with_status(Status::ServiceUnavailable).halt();
    };

    let mut fortunes = match query_fortunes(pool).await {
        Ok(rows) => rows,
        Err(e) => {
            log::warn!("fortunes query failed: {e}");
            return conn.with_status(Status::InternalServerError).halt();
        }
    };

    fortunes.push(Fortune {
        id: 0,
        message: "Additional fortune added at request time.".into(),
    });
    fortunes.sort_by(|a, b| a.message.as_bytes().cmp(b.message.as_bytes()));

    conn.render(FortunesTemplate { fortunes })
        .with_response_header(KnownHeaderName::ContentType, "text/html; charset=utf-8")
}

async fn query_fortunes(
    pool: &Pool,
) -> Result<Vec<Fortune>, Box<dyn std::error::Error + Send + Sync>> {
    let client = pool.get().await?;
    let stmt = client
        .prepare_cached("SELECT id, message FROM fortune")
        .await?;
    let rows = client.query(&stmt, &[]).await?;
    Ok(rows
        .into_iter()
        .map(|row| Fortune {
            id: row.get(0),
            message: row.get(1),
        })
        .collect())
}
