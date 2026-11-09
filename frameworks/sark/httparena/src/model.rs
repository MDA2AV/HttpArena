use o3::buffer::storage::Shared;

#[derive(Debug)]
#[sark_json::json]
pub struct Rating {
    pub score: u64,
    pub count: u64,
}

#[derive(Debug)]
#[sark_json::json]
pub struct Item {
    pub id: u64,
    pub name: Shared,
    pub category: Shared,
    pub price: u64,
    pub quantity: u64,
    pub active: bool,
    #[field(seq)]
    pub tags: Vec<Shared>,
    #[field(nested)]
    pub rating: Rating,
}
