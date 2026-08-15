use serde::Serialize;
use wtx::{
  codec::i64_string,
  collections::{ArrayVectorU8, Vector},
  http::{
    Header, HttpRecvParams, KnownHeaderName, MsgDataMut, StatusCode,
    http2_server_framework::{
      Http2ServerFramework, HttpRouter, JsonReply, Path, State, VerbatimParams, get,
    },
  },
  misc::Wrapper,
  sync::Arc,
  tls::TlsConfig,
};

fn main() -> wtx::Result<()> {
  let dataset = load_dataset();
  let router = HttpRouter::paths(wtx::paths!(
    ("/baseline2", get(endpoint_baseline2)),
    ("/json/{count}", get(endpoint_json)),
  ))?;
  Http2ServerFramework::tokio(TlsConfig::plaintext())?
    .set_data(ConnAux { dataset })
    .set_http_recv_params(HttpRecvParams::with_permissive_params())
    .run_in_threads("0.0.0.0:8082", router)
}

#[derive(Clone, wtx::Lease)]
struct ConnAux {
  dataset: Arc<Vector<DatasetItem>>,
}

async fn endpoint_baseline2(state: State<'_, ConnAux>) -> wtx::Result<VerbatimParams> {
  let mut sum: i64 = 0;
  for (_, value) in state.req.msg_data.uri.query_params() {
    sum = sum.wrapping_add(value.parse()?);
  }
  state.req.msg_data.clear();
  state.req.msg_data.body.extend_from_copyable_slice(i64_string(sum).as_bytes())?;
  state.req.msg_data.headers.push_from_iter_many([
    Header::from_name_and_value(KnownHeaderName::ContentType.into(), ["text/plain"].into_iter()),
    Header::from_name_and_value(KnownHeaderName::Server.into(), ["wtx"].into_iter()),
  ])?;
  Ok(VerbatimParams(StatusCode::Ok))
}

async fn endpoint_json(
  state: State<'_, ConnAux>,
  Path(count): Path<usize>,
) -> wtx::Result<JsonReply> {
  let mut m: f64 = 1.0;
  for (key, value) in state.req.msg_data.uri.query_params() {
    if key != "m" {
      continue;
    }
    m = f64::from(value.parse::<i32>()?);
    break;
  }
  let dataset_len = state.data.dataset.len();
  let clamped = if count > dataset_len { dataset_len } else { count };
  state.req.msg_data.clear();
  let items = state.data.dataset.iter().take(clamped).map(move |el| {
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
  serde_json::to_writer(&mut state.req.msg_data.body, &resp)?;
  let header = Header::from_name_and_value(KnownHeaderName::Server.into(), ["wtx"]);
  state.req.msg_data.headers.push_from_iter(header)?;
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
