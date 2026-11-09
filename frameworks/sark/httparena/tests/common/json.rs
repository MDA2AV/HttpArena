use httparena_sark::json;
use o3::buffer::storage::Shared;
use sark::http::payload::response::dispatch::IntoOutput;
use sark_json::writing::Body;

pub fn encode(listing: json::Listing<'_>) -> Shared {
    let response = Body::new(listing)
        .try_response()
        .map_err(|rejected| rejected.discard())
        .expect("bound");
    let (_, _, plan) = response.into_output().into_parts();
    plan.into_shared().expect("bounded body")
}

pub const DATASET: &[u8] = br#"[
    {"id":8,"name":"A\"B","category":"tools","price":3,"quantity":4,"active":true,"tags":["x","y"],"rating":{"score":5,"count":6}},
    {"id":2,"name":"C","category":"other","price":11,"quantity":2,"active":false,"tags":[],"rating":{"score":0,"count":9}}
]"#;

pub const LISTING: &[u8] = br#"{"items":[{"id":8,"name":"A\"B","category":"tools","price":3,"quantity":4,"active":true,"tags":["x","y"],"rating":{"score":5,"count":6},"total":84},{"id":2,"name":"C","category":"other","price":11,"quantity":2,"active":false,"tags":[],"rating":{"score":0,"count":9},"total":154}],"count":2}"#;

pub const FIRST: &[u8] = br#"{"items":[{"id":1,"name":"Alpha Widget","category":"electronics","price":328,"quantity":15,"active":true,"tags":["sale","heavy-duty","popular"],"rating":{"score":48,"count":53},"total":14760}],"count":1}"#;

pub const SUFFIX: &[u8] = br#", "extra": []"#;

pub const EMPTY: &[u8] = b"[]";

pub const EXTREMES: &[u8] = br#"[
    {"id":1,"name":"zero","category":"a","price":18446744073709551615,"quantity":0,"active":true,"tags":[],"rating":{"score":0,"count":0}},
    {"id":2,"name":"overflow","category":"a","price":18446744073709551615,"quantity":2,"active":true,"tags":[],"rating":{"score":0,"count":0}}
]"#;
