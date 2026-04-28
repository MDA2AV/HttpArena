use serde::Serialize;
use wtx::{
  codec::i64_string,
  collection::{ArrayVectorU8, Vector},
  http::{
    Header, HttpRecvParams, KnownHeaderName, ReqResBuffer, StatusCode,
    server_framework::{
      JsonReply, PathOwned, Router, ServerFrameworkBuilder, State, VerbatimParams, get,
    },
  },
  misc::Wrapper,
  sync::Arc,
};

#[derive(Clone, wtx::ConnAux)]
struct ConnAux {
  dataset: Arc<Vector<DatasetItem>>,
}

#[tokio::main]
async fn main() -> wtx::Result<()> {
  let dataset = load_dataset();
  let router = Router::paths(wtx::paths!(
    ("/baseline2", get(endpoint_baseline2)),
    ("/json/{count}", get(endpoint_json)),
  ))?;
  ServerFrameworkBuilder::new(HttpRecvParams::with_permissive_params(), router)
    .with_conn_aux(move || Ok(ConnAux { dataset: dataset.clone() }))
    .tokio(
      "0.0.0.0:8082",
      |_error| {},
      |_| Ok(()),
      |stream| {
        stream.set_nodelay(true)?;
        Ok(())
      },
      |_error| {},
    )
    .await
}

async fn endpoint_baseline2(
  state: State<'_, ConnAux, (), ReqResBuffer>,
) -> wtx::Result<VerbatimParams> {
  let mut sum: i64 = 0;
  for (_, value) in state.req.rrd.uri.query_params() {
    sum = sum.wrapping_add(value.parse()?);
  }
  state.req.rrd.clear();
  state.req.rrd.body.extend_from_copyable_slice(i64_string(sum).as_bytes())?;
  state.req.rrd.headers.push_from_iter_many([
    Header::from_name_and_value(KnownHeaderName::ContentType.into(), ["text/plain"].into_iter()),
    Header::from_name_and_value(KnownHeaderName::Server.into(), ["wtx"].into_iter())
  ])?;
  Ok(VerbatimParams(StatusCode::Ok))
}

async fn endpoint_json(
  state: State<'_, ConnAux, (), ReqResBuffer>,
  PathOwned(count): PathOwned<usize>,
) -> wtx::Result<JsonReply> {
  let mut m: f64 = 1.0;
  for (key, value) in state.req.rrd.uri.query_params() {
    if key != "m" {
      continue;
    }
    m = f64::from(value.parse::<i32>()?);
    break;
  }
  let dataset_len = state.conn_aux.dataset.len();
  let clamped = if count > dataset_len { dataset_len } else { count };
  state.req.rrd.clear();
  let items = state.conn_aux.dataset.iter().take(clamped).map(move |el| {
    Ok(ProcessedItem {
      id: el.id,
      name: &el.name,
      category: &el.category,
      price: el.price,
      quantity: el.quantity,
      active: el.active,
      tags: ArrayVectorU8::from_iterator(el.tags.iter().map(|el| el.as_str()))?,
      rating: RatingOut { score: el.rating.score, count: el.rating.count },
      total: el.price * el.quantity * m,
    })
  });
  let resp = JsonResponse { count: clamped, items: Wrapper(items) };
  serde_json::to_writer(&mut state.req.rrd.body, &resp).unwrap_or_default();
  let header = Header::from_name_and_value(KnownHeaderName::Server.into(), ["wtx"]);
  state.req.rrd.headers.push_from_iter(header)?;
  Ok(JsonReply(StatusCode::Ok))
}

fn load_dataset() -> Arc<Vector<DatasetItem>> {
  let path = std::env::var("DATASET_PATH").unwrap_or_else(|_| "/data/dataset.json".to_string());
  Arc::new(match std::fs::read_to_string(&path) {
    Ok(data) => serde_json::from_str(&data).unwrap_or_default(),
    Err(_) => Vector::new(),
  })
}

#[derive(serde::Deserialize)]
struct DatasetItem {
  id: i64,
  name: String,
  category: String,
  price: f64,
  quantity: f64,
  active: bool,
  tags: ArrayVectorU8<String, 6>,
  rating: Rating,
}

#[derive(serde::Serialize)]
#[serde(bound = "E: Serialize")]
struct JsonResponse<E, I>
where
  I: Clone + Iterator<Item = wtx::Result<E>>,
  E: Serialize,
{
  items: Wrapper<I>,
  count: usize,
}

#[derive(serde::Serialize)]
struct ProcessedItem<'any> {
  id: i64,
  name: &'any str,
  category: &'any str,
  price: f64,
  quantity: f64,
  active: bool,
  tags: ArrayVectorU8<&'any str, 6>,
  rating: RatingOut,
  total: f64,
}

#[derive(serde::Deserialize)]
struct Rating {
  score: f64,
  count: i64,
}

#[derive(serde::Serialize)]
struct RatingOut {
  score: f64,
  count: i64,
}
