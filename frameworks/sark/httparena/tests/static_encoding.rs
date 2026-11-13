pub mod common;

use std::{fs, process::Command};

use dope_test::harness::server::Pair;
use httparena_sark::runtime::{self, Bindings};

#[test]
fn selects_available_static_encoding_and_preserves_content_headers() {
    let pair = Pair::bind().expect("HTTP listener");
    let worker = common::http::worker(pair.addr());
    let root = worker.boot.static_root.clone();
    pair.run(
        move |context, http| {
            runtime::serve(
                worker,
                context,
                Bindings {
                    http: Some(http),
                    ..Default::default()
                },
            )
            .map(drop)
        },
        |address| {
            for (name, headers, status, content_type, encoding, suffix) in [
                (
                    "reset.css",
                    &[][..],
                    b"200".as_slice(),
                    b"text/css; charset=utf-8".as_slice(),
                    b"".as_slice(),
                    "",
                ),
                (
                    "reset.css",
                    &["gzip, br"][..],
                    b"200",
                    b"text/css; charset=utf-8",
                    b"br",
                    ".br",
                ),
                (
                    "reset.css",
                    &["gzip;q=1, br;q=0.5, identity;q=0"][..],
                    b"200",
                    b"text/css; charset=utf-8",
                    b"gzip",
                    ".gz",
                ),
                (
                    "reset.css",
                    &["br, gzip", "br;q=0, *;q=0"][..],
                    b"200",
                    b"text/css; charset=utf-8",
                    b"gzip",
                    ".gz",
                ),
                (
                    "hero.webp",
                    &["br, gzip"][..],
                    b"200",
                    b"image/webp",
                    b"",
                    "",
                ),
                (
                    "hero.webp",
                    &["*;q=0"][..],
                    b"406",
                    b"text/plain",
                    b"",
                    "",
                ),
            ] {
                let mut request = Command::new("curl");
                request.args([
                    "--silent",
                    "--show-error",
                    "--max-time",
                    "5",
                    "--write-out",
                    "\n%{http_code}\n%header{content-type}\n%header{content-encoding}\n%header{vary}",
                ]);
                for header in headers {
                    request.args(["--header", &format!("Accept-Encoding: {header}")]);
                }
                let output = request
                    .arg(format!("http://{address}/static/{name}"))
                    .output()
                    .expect("static request");
                assert!(
                    output.status.success(),
                    "curl failed: {}",
                    String::from_utf8_lossy(&output.stderr)
                );
                let mut fields = output.stdout.rsplitn(5, |byte| *byte == b'\n');
                assert_eq!(fields.next(), Some(b"Accept-Encoding".as_slice()));
                assert_eq!(fields.next(), Some(encoding));
                assert_eq!(fields.next(), Some(content_type));
                assert_eq!(fields.next(), Some(status));
                let expected = if status == b"200" {
                    fs::read(root.join(format!("{name}{suffix}"))).expect("static representation")
                } else {
                    Vec::new()
                };
                assert_eq!(fields.next(), Some(expected.as_slice()));
            }
        },
    )
    .expect("static application");
}
