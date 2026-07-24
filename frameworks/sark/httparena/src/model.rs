use cartel_gen::{pg_instance, query_group};
use cartel_pg::{Jsonb, PgTable, Text};

pub struct Item {
    pub id: i32,
    pub name: &'static [u8],
    pub category: &'static [u8],
    pub price: i32,
    pub quantity: i32,
    pub active: bool,
    pub tags: &'static [&'static [u8]],
    pub rating_score: i32,
    pub rating_count: i32,
}

#[derive(PgTable, Debug, Clone)]
#[table_name("items")]
pub struct ItemRow {
    #[pk]
    pub id: i32,
    pub name: String,
    pub category: String,
    pub price: i32,
    pub quantity: i32,
    pub active: bool,
    pub tags: Jsonb,
    pub rating_score: i32,
    pub rating_count: i32,
}

#[query_group]
impl ItemRow {
    pub fn by_id(id: i32) -> Option<ItemRow> {
        ItemRow::filter(|r| r.id == id).first()
    }

    pub fn range(min: i32, max: i32, limit: i64) -> Vec<ItemRow> {
        ItemRow::filter(|r| r.price >= min && r.price <= max)
            .limit(limit)
            .all()
    }

    pub fn by_category_paged(category: &str, limit: i64, offset: i64) -> Vec<ItemRow> {
        ItemRow::filter(|r| r.category == category)
            .order_by(|r| r.id)
            .limit(limit)
            .offset(offset)
            .all()
    }

    pub fn create(
        id: i32,
        name: String,
        category: String,
        price: i32,
        quantity: i32,
        active: bool,
        tags: Jsonb,
        rating_score: i32,
        rating_count: i32,
    ) {
        ItemRow::insert(|r| {
            r.id = id;
            r.name = name;
            r.category = category;
            r.price = price;
            r.quantity = quantity;
            r.active = active;
            r.tags = tags;
            r.rating_score = rating_score;
            r.rating_count = rating_count;
        })
        .on_conflict_do_nothing()
    }

    pub fn update_fields(id: i32, name: String, price: i32, quantity: i32) {
        ItemRow::filter(|r| r.id == id).update(|r| {
            r.name = name;
            r.price = price;
            r.quantity = quantity;
        })
    }
}

#[derive(PgTable, Debug)]
#[table_name("fortune")]
pub struct Fortune {
    #[pk]
    pub id: i32,
    pub message: Text,
}

#[query_group]
impl Fortune {
    pub fn all_rows() -> Vec<Fortune> {
        Fortune::filter(|_f| true).all()
    }
}

pg_instance! { Db: ItemRow, Fortune }
