pub mod common;

use std::path::Path;

use httparena_sark::{dataset, json};

use common::json::encode;

#[test]
fn loads_dataset_and_serializes_requested_prefix() {
    let dataset = dataset::Dataset::load(Path::new(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../data/dataset.json"
    )))
    .expect("dataset");
    assert_eq!(
        encode(json::items(&dataset, 0, 3).expect("items")).as_ref(),
        common::json::FIRST
    );
    assert_eq!(
        encode(json::items(&dataset, usize::MAX, 97).expect("items")).as_ref(),
        encode(json::items(&dataset, 50, 97).expect("items")).as_ref(),
    );
}

#[test]
fn preserves_loaded_values_and_computes_each_total() {
    let dataset = dataset::Dataset::from_json(common::json::DATASET.to_vec()).expect("dataset");
    assert_eq!(
        encode(json::items(&dataset, 50, 7).expect("items")).as_ref(),
        common::json::LISTING
    );
    for (count, multiplier) in [(50, u64::MAX / 22), (1, u64::MAX / 12)] {
        encode(json::items(&dataset, count, multiplier).expect("items"));
    }
    assert!(matches!(
        json::items(&dataset, 1, u64::MAX),
        Err(json::Error::Overflow)
    ));
    assert!(matches!(
        json::items(&dataset, 2, u64::MAX / 12),
        Err(json::Error::Overflow)
    ));
    let extremes =
        dataset::Dataset::from_json(common::json::EXTREMES.to_vec()).expect("extreme dataset");
    encode(json::items(&extremes, 1, u64::MAX).expect("zero total"));
    assert!(matches!(
        json::items(&extremes, 2, 1),
        Err(json::Error::Overflow)
    ));
    assert!(
        encode(json::items(&extremes, 2, 0).expect("zero multiplier"))
            .as_ref()
            .ends_with(b",\"total\":0}],\"count\":2}")
    );
    assert!(matches!(
        dataset::Dataset::from_json(common::json::EMPTY.to_vec()),
        Err(dataset::Error::Empty)
    ));
    let mut invalid = common::json::DATASET.to_vec();
    invalid.extend_from_slice(common::json::SUFFIX);
    assert!(matches!(
        dataset::Dataset::from_json(invalid),
        Err(dataset::Error::Json(_))
    ));
}
