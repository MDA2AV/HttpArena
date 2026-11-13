pub mod common;

use dope_test::harness::server::Pair;
use httparena_sark::runtime::{self, Bindings};

use common::http;

#[test]
fn application_preserves_empty_database_and_query_errors() {
    let pair = Pair::bind().expect("HTTP listener");
    let worker = http::worker(pair.addr());
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
            for (path, status, body) in [
                ("/async-db", 200, br#"{"items":[],"count":0}"#.as_slice()),
                ("/async-db?min=x", 400, b"invalid integer".as_slice()),
                (
                    "/baseline11?a=18446744073709551615&b=1",
                    400,
                    b"integer overflow".as_slice(),
                ),
            ] {
                assert_eq!(http::request(address, path, None), (status, body.to_vec()));
            }
        },
    )
    .expect("HTTP application");
}
