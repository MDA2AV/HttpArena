//! `/fortunes`: rows from Postgres plus one added at request time, sorted by
//! message and rendered through the sailfish template `templates/fortunes.stpl`.

use std::ptr;

use ntex::util::Bytes;
use ntex::web::HttpResponse;
use ntex_bytes::{StorageExt, StorageVTable};
use sailfish::{TemplateSimple, runtime::Buffer};

use crate::db;

/// The row every request appends to the database rows before sorting.
const RUNTIME_MESSAGE: &str = "Additional fortune added at request time.";
/// Room for the rendered 201-row page, so rendering never reallocates.
/// The ~25 KB page fills more than half of it, so shrinking the buffer to
/// the page keeps the allocation in place.
const PAGE_CAPACITY: usize = 32 * 1024;

/// A rendered page that becomes the response body without copying.
struct Page(Box<[u8]>);

// SAFETY: `create` leaks the box and `page_drop` frees it once; the page is
// not modified while `Bytes` holds it.
unsafe impl StorageExt for Page {
    fn create(self) -> (*const u8, usize, &'static StorageVTable) {
        static VTABLE: StorageVTable =
            StorageVTable::new(page_ptr, page_len, page_clone, page_drop);
        let len = self.0.len();
        (Box::into_raw(self.0).cast::<u8>(), len, &VTABLE)
    }
}

fn page_ptr(addr: *const u8, _: usize) -> *const u8 {
    addr
}

fn page_len(_: *const u8, len: usize) -> usize {
    len
}

/// Clones copy the page.
fn page_clone(_: *const u8, _: usize) -> Option<(*const u8, usize)> {
    None
}

/// # Safety
///
/// `(addr, len)` is the pair returned by `Page::create`, passed once.
unsafe fn page_drop(addr: *const u8, len: usize) {
    // SAFETY: the pair comes from `Box::into_raw` in `Page::create`
    drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(addr.cast_mut(), len)) });
}

pub struct Fortune<'a> {
    pub id: i32,
    pub message: &'a str,
}

/// `<%= %>` escapes `&"'<>` with named entities (`&lt;`), as the validator
/// expects.
#[derive(TemplateSimple)]
#[template(path = "fortunes.stpl")]
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

    let mut buf = Buffer::with_capacity(PAGE_CAPACITY);
    match (FortunesTemplate {
        fortunes: &fortunes,
    })
    .render_once_to(&mut buf)
    {
        Ok(()) => HttpResponse::Ok()
            .content_type("text/html; charset=utf-8")
            .body(Bytes::from_ext(Page(
                buf.into_string().into_bytes().into_boxed_slice(),
            ))),
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
    use ntex::http::body::{Body, ResponseBody};
    use ntex::web::test;
    use ntex_bytes::info::Kind;

    /// STATEMENT: The rendered page becomes the response body without being
    /// copied into ntex storage.
    ///
    /// HOW:
    /// - Render one row.
    /// - Confirm the body is `Body::Bytes` backed by external storage
    ///   (`Kind::StExt`), which is the `Page` holding the render buffer.
    #[test]
    fn page_body_is_not_copied() {
        let response = render(vec![Fortune {
            id: 1,
            message: "one",
        }]);
        let ResponseBody::Body(Body::Bytes(page)) = response.body() else {
            panic!("unexpected body");
        };
        assert_eq!(page.info().kind, Kind::StExt);
    }

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
            "<td>1</td><td>Z &quot;quoted&quot; &amp; &#039;single&#039;</td>",
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
