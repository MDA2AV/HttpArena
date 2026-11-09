use cartel_pg::schema::Project;
use httparena_sark::db::{ItemRow, ItemRowView};

pub const UPDATE: &[u8] = br#"{"quantity":22,"name":"updated \"item\"","price":-111}"#;
pub const UPDATED_ROW: &[u8] = br#"{"id":7,"name":"updated \"item\"","category":"auto","price":-111,"quantity":22,"active":false,"tags":["popular"],"rating":{"score":41,"count":428}}"#;
pub const PRICE_OVERFLOW: &[u8] = br#"{"name":"item","price":2147483648,"quantity":22}"#;
pub const TAGS: &str = r#"["red","a\\b"]"#;
pub const ITEM: &[u8] = br#"{"id":7,"name":"A \"quoted\" item","category":"hardware","price":13,"quantity":9,"active":true,"tags":["red","a\\b"],"rating":{"score":4,"count":27}}"#;
pub const HTML: &str = "<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table><tr><th>id</th><th>message</th></tr><tr><td>1</td><td>&lt;script&gt;&#x27;&quot;&amp;&lt;/script&gt;</td></tr><tr><td>0</td><td>Additional fortune added at request time.</td></tr><tr><td>2</td><td>Zulu</td></tr><tr><td>3</td><td>é</td></tr></table></body></html>";

pub fn item(tags: &str) -> ItemRowView<'_> {
    ItemRow::project((
        7,
        (
            "A \"quoted\" item",
            ("hardware", (13, (9, (true, (tags, (4, (27, ()))))))),
        ),
    ))
}

pub fn fortunes() -> Vec<(i32, &'static str)> {
    vec![(3, "é"), (1, "<script>'\"&</script>"), (2, "Zulu")]
}

pub fn oversized_fortune() -> String {
    "x".repeat(httparena_sark::db::MAX_BODY_BYTES)
}

pub fn updated_range() -> Vec<u8> {
    [b"{\"items\":[".as_slice(), UPDATED_ROW, b"],\"count\":1}"].concat()
}
