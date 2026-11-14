//! `/fortunes`: rows from Postgres plus one added at request time, sorted by
//! message and rendered through the Askama template `templates/fortunes.html`.

use std::fmt;

use actix_web::{web, HttpResponse};
use askama::{filters::Escaper, Template};
use deadpool_postgres::Pool;

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

    let mut page = String::with_capacity(PAGE_CAPACITY);
    match (FortunesTemplate {
        fortunes: &fortunes,
    })
    .render_into(&mut page)
    {
        Ok(()) => HttpResponse::Ok()
            .content_type("text/html; charset=utf-8")
            .body(page),
        Err(_) => HttpResponse::InternalServerError().finish(),
    }
}

/// The rendered page, or `500` without a database or on a database error.
pub async fn fortunes(pool: web::Data<Option<Pool>>) -> HttpResponse {
    let Some(rows) = db::fortunes(&pool).await else {
        return HttpResponse::InternalServerError().finish();
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
