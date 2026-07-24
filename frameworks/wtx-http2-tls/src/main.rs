use wtx::{
  codec::i64_string,
  http::{
    Header, HttpRecvParams, KnownHeaderName, MsgDataMut, StatusCode,
    http2_server_framework::{Http2ServerFramework, HttpRouter, State, VerbatimParams, get},
  },
  tls::{TlsConfig, TlsModeVerified},
};

fn main() -> wtx::Result<()> {
  let cert_path = wtx::misc::var("TLS_CERT").unwrap_or_else(|_| "/certs/server.crt".to_string());
  let key_path = wtx::misc::var("TLS_KEY").unwrap_or_else(|_| "/certs/server.key".to_string());
  let cert_file = std::fs::read_to_string(&cert_path)?.into_bytes();
  let key_file = std::fs::read_to_string(&key_path)?.into_bytes();
  let tls_config = TlsConfig::from_keys_pem(TlsModeVerified::new(), &cert_file, &key_file)?;
  let router = HttpRouter::paths(wtx::paths!(("/baseline2", get(endpoint_baseline)),))?;
  Http2ServerFramework::tokio(tls_config)?
    .set_http_recv_params(HttpRecvParams::with_permissive_params())
    .run_in_threads("0.0.0.0:8443", router)
}

async fn endpoint_baseline(state: State<'_, ()>) -> wtx::Result<VerbatimParams> {
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
