//! `/fortunes`: rows from Postgres plus one added at request time, sorted by
//! message and rendered through the Askama template `templates/fortunes.html`.

use std::fmt;

use askama::{Template, filters::Escaper};
use ntex::util::BytesMut;
use ntex::web::HttpResponse;

use crate::db;

/// The row every request appends to the database rows before sorting.
const RUNTIME_MESSAGE: &str = "Additional fortune added at request time.";
/// Room for the rendered 201-row page, so rendering never reallocates.
const PAGE_CAPACITY: usize = 32 * 1024;

/// HTML escaper for `.html` templates, registered in `askama.toml`.
///
/// Askama's built-in escaper writes numeric entities (`&#60;`), while the
/// validator looks for the named `&lt;script&gt;`.
#[derive(Copy, Clone)]
pub struct NamedHtml;

impl Escaper for NamedHtml {
    fn write_escaped_str<W: fmt::Write>(&self, mut dest: W, s: &str) -> fmt::Result {
        let mut last = 0;
        for (i, b) in s.bytes().enumerate() {
            let entity = match b {
                b'<' => "&lt;",
                b'>' => "&gt;",
                b'&' => "&amp;",
                b'"' => "&quot;",
                b'\'' => "&#39;",
                _ => continue,
            };
            dest.write_str(&s[last..i])?;
            dest.write_str(entity)?;
            last = i + 1;
        }
        dest.write_str(&s[last..])
    }
}

pub struct Fortune<'a> {
    pub id: i32,
    pub message: &'a str,
}

#[derive(Template)]
#[template(path = "fortunes.html")]
struct FortunesTemplate<'a> {
    fortunes: &'a [Fortune<'a>],
}

/// Appends the runtime row, sorts by message in byte order and renders the
/// page; messages are HTML-escaped by the template.
fn render(mut fortunes: Vec<Fortune<'_>>) -> HttpResponse {
    fortunes.push(Fortune {
        id: 0,
        message: RUNTIME_MESSAGE,
    });
    fortunes.sort_unstable_by(|a, b| a.message.cmp(b.message));

    let mut page = BytesMut::with_capacity(PAGE_CAPACITY);
    match (FortunesTemplate {
        fortunes: &fortunes,
    })
    .render_into(&mut page)
    {
        Ok(()) => HttpResponse::Ok()
            .content_type("text/html; charset=utf-8")
            .body(page),
        Err(_) => HttpResponse::InternalServerError().build(),
    }
}

/// The rendered page, or `500` without a database or on a database error.
pub async fn fortunes() -> HttpResponse {
    let Some(rows) = db::fortunes().await else {
        return HttpResponse::InternalServerError().build();
    };
    render(
        rows.iter()
            .map(|row| Fortune {
                id: row.get(0),
                message: row.get(1),
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use ntex::http::StatusCode;
    use ntex::web::test;

    async fn page(response: HttpResponse) -> String {
        String::from_utf8(test::read_body(response).await.to_vec()).unwrap()
    }

    /// STATEMENT: `render` appends the runtime row, sorts by message in byte
    /// order and HTML-escapes every message.
    ///
    /// HOW:
    /// - Render rows with a `<script>` message, quotes, an ampersand and a
    ///   non-ASCII message.
    /// - Confirm `200` and `Content-Type: text/html; charset=utf-8`.
    /// - Confirm the escaped script row comes first, then `A ...`, the runtime
    ///   row, `Z ...` and the non-ASCII row, that no raw `<script>` appears, and
    ///   that `&`, `"` and `'` are escaped.
    #[ntex::test]
    async fn render_sorts_and_escapes() {
        let response = render(vec![
            Fortune {
                id: 3,
                message: "フレームワーク",
            },
            Fortune {
                id: 1,
                message: "Z \"quoted\" & 'single'",
            },
            Fortune {
                id: 11,
                message: "<script>alert(1);</script>",
            },
            Fortune {
                id: 2,
                message: "A first",
            },
        ]);
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response.headers().get("Content-Type").unwrap(),
            "text/html; charset=utf-8"
        );
        let page = page(response).await;
        assert!(!page.contains("<script>"));

        let order = [
            "<td>11</td><td>&lt;script&gt;alert(1);&lt;/script&gt;</td>",
            "<td>2</td><td>A first</td>",
            "<td>0</td><td>Additional fortune added at request time.</td>",
            "<td>1</td><td>Z &quot;quoted&quot; &amp; &#39;single&#39;</td>",
            "<td>3</td><td>フレームワーク</td>",
        ];
        let positions: Vec<_> = order
            .iter()
            .map(|row| {
                page.find(row)
                    .unwrap_or_else(|| panic!("{row} missing in {page}"))
            })
            .collect();
        assert!(positions.is_sorted(), "rows out of order: {page}");
    }

    /// STATEMENT: Without a database `/fortunes` fails with `500`.
    ///
    /// HOW:
    /// - Call `fortunes` on a thread where `db::init` never opened a pool.
    /// - Confirm the status is `500 Internal Server Error`.
    #[ntex::test]
    async fn error_without_database() {
        assert_eq!(fortunes().await.status(), StatusCode::INTERNAL_SERVER_ERROR);
    }
}
