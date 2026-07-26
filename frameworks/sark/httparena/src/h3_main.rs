use std::collections::HashMap;
use std::io;
use std::net::SocketAddr;

use dope::launcher::{Ctx, Launcher};
use dope::{DriverCfg, DriverConfig, Executor};
use dope_quic::{Conn, ConnConfig, ConnHandle, Endpoint, Handler, StreamEvent, transport_params};
use sark::fs::ServeDir;
use sark_core::http::Field;
use sark_h3::dope::Session;
use sark_h3::{Event, Role, StreamId};

struct H3Handler {
    sessions: HashMap<ConnHandle, Session>,
    serve: &'static ServeDir,
}

impl H3Handler {
    fn ensure_session(&mut self, conn: &mut Conn, handle: ConnHandle) {
        if !self.sessions.contains_key(&handle) {
            let mut session = Session::with_role(Role::Server);
            let _ = session.start_control_stream(conn);
            self.sessions.insert(handle, session);
        }
    }

    fn serve(
        session: &mut Session,
        stream_id: StreamId,
        path: &[u8],
        accept_encoding: &[u8],
        serve: &'static ServeDir,
    ) {
        let seg = match path.iter().position(|&b| b == b'?') {
            Some(q) => &path[..q],
            None => path,
        };
        if let Some(file) = seg.strip_prefix(b"/static/") {
            let response = serve.serve(file, accept_encoding);
            let status = response.status();
            let mut status_buf = [0u8; 3];
            let code = status.as_u16();
            status_buf[0] = b'0' + (code / 100 % 10) as u8;
            status_buf[1] = b'0' + (code / 10 % 10) as u8;
            status_buf[2] = b'0' + (code % 10) as u8;
            let ctype = response
                .headers()
                .get("content-type")
                .map(|v| v.as_bytes())
                .unwrap_or(b"application/octet-stream");
            let encoding = Self::wire_header_value(response.wire_headers(), b"content-encoding");
            Self::write_response(
                session,
                stream_id,
                &status_buf,
                ctype,
                encoding,
                response.body(),
            );
            return;
        }
        let (status, ctype, body) = httparena_sark::h2bench::BenchHandler::route(path);
        Self::write_response(session, stream_id, status, ctype, b"", &body[..]);
    }

    fn wire_header_value<'a>(wire: &'a [u8], name: &[u8]) -> &'a [u8] {
        for line in wire.split(|&b| b == b'\n') {
            let line = line.strip_suffix(b"\r").unwrap_or(line);
            let Some(colon) = line.iter().position(|&b| b == b':') else {
                continue;
            };
            let (hname, rest) = line.split_at(colon);
            if hname.eq_ignore_ascii_case(name) {
                return rest[1..].trim_ascii_start();
            }
        }
        b""
    }

    fn write_response(
        session: &mut Session,
        stream_id: StreamId,
        status: &[u8],
        ctype: &[u8],
        content_encoding: &[u8],
        body: &[u8],
    ) {
        let len = body.len().to_string();
        let encoded = !content_encoding.is_empty() && content_encoding != b"identity";
        let fields_full = [
            Field::new(b":status", status),
            Field::new(b"content-type", ctype),
            Field::new(b"content-length", len.as_bytes()),
            Field::new(b"content-encoding", content_encoding),
        ];
        let fields: &[Field] = if encoded {
            &fields_full
        } else {
            &fields_full[..3]
        };
        if session
            .h3_mut()
            .send_headers(stream_id, fields.iter().copied(), body.is_empty())
            .is_err()
        {
            return;
        }
        if !body.is_empty() {
            let _ = session.h3_mut().send_data(stream_id, body, true);
        }
    }
}

impl Handler for H3Handler {
    fn on_established(&mut self, conn: &mut Conn, handle: ConnHandle) {
        self.ensure_session(conn, handle);
    }

    fn on_stream_event(&mut self, conn: &mut Conn, handle: ConnHandle, event: StreamEvent) {
        let serve = self.serve;
        self.ensure_session(conn, handle);
        let session = self.sessions.get_mut(&handle).expect("session ensured");
        if session.on_quic_stream_event(conn, event).is_err() {
            return;
        }
        while let Some(ev) = session.poll_event() {
            if let Event::Headers {
                stream_id,
                fields,
                trailing,
            } = ev
            {
                if trailing {
                    continue;
                }
                let path = fields
                    .iter()
                    .find(|f| f.name == b":path")
                    .map(|f| f.value.clone())
                    .unwrap_or_else(|| b"/".to_vec());
                let accept_encoding = fields
                    .iter()
                    .find(|f| f.name == b"accept-encoding")
                    .map(|f| f.value.clone())
                    .unwrap_or_default();
                Self::serve(session, stream_id, &path, &accept_encoding, serve);
            }
        }
        session.flush(conn);
    }

    fn on_close(&mut self, handle: ConnHandle) {
        self.sessions.remove(&handle);
    }
}

#[pin_project::pin_project(!Unpin)]
#[derive(dope_gen::Dispatcher)]
struct Dispatcher {
    #[pin]
    #[manifold]
    quic: Endpoint<0, H3Handler>,
}

const RETRY_SECRET: [u8; 32] = [
    0x9f, 0x3c, 0x71, 0x05, 0xe8, 0x2a, 0xb6, 0x4d, 0x13, 0xc0, 0x6e, 0x97, 0x5b, 0xf1, 0x82, 0x2d,
    0x48, 0xaa, 0x0f, 0xd6, 0x39, 0x7c, 0xe1, 0x54, 0x86, 0x2b, 0x9d, 0x10, 0xcf, 0x63, 0x74, 0xb8,
];

fn run_thread(ctx: Ctx, bind: SocketAddr, serve: &'static ServeDir) -> io::Result<()> {
    let driver_cfg = DriverCfg::for_quic_udp(4096, 2048).with_cpu_id(Some(ctx.cpu));
    let mut exec = Executor::new(driver_cfg)?;

    let (chain_der, signing_key) = httparena_sark::tls::quic_cert();
    let tp = transport_params::Params {
        max_idle_timeout_ms: 30_000,
        initial_max_data: 64 << 20,
        initial_max_stream_data_bidi_local: 1 << 20,
        initial_max_stream_data_bidi_remote: 1 << 20,
        initial_max_stream_data_uni: 1 << 20,
        initial_max_streams_bidi: 256,
        initial_max_streams_uni: 16,
        active_connection_id_limit: 4,
        ..Default::default()
    };
    let require_av = std::env::var("SARK_H3_REQUIRE_ADDR_VALIDATION")
        .map(|v| v != "0")
        .unwrap_or(false);
    let server_config = ConnConfig {
        alpn_protocols: vec![b"h3".to_vec()],
        server_cert_chain: Some(chain_der),
        require_address_validation: require_av,
        retry_token_secret: if require_av { Some(RETRY_SECRET) } else { None },
        ..ConnConfig::from(tp)
    };

    let handler = H3Handler {
        sessions: HashMap::new(),
        serve,
    };
    let endpoint = {
        let drv = exec.driver_mut();
        Endpoint::<0, _>::build_server_with_config(bind, signing_key, server_config, handler, drv)?
    };

    let mut app = core::pin::pin!(Dispatcher { quic: endpoint });
    exec.run(app.as_mut())
}

fn main() -> io::Result<()> {
    let boot = httparena_sark::boot::Boot::from_env(8443);
    let static_dir = std::env::var("STATIC_DIR").unwrap_or_else(|_| "/data/static".into());
    let serve: &'static ServeDir = Box::leak(Box::new(
        ServeDir::new(static_dir)
            .precompressed_br()
            .precompressed_gzip(),
    ));
    let bind = boot.bind;

    let total = boot.cpus.len();
    let h2_core_count = if total <= 1 {
        total
    } else {
        2usize.min(total - 1)
    };
    let h2_cpus: std::collections::HashSet<u16> =
        boot.cpus.iter().take(h2_core_count).copied().collect();

    let h2_cfg = sark_h2::server::Cfg {
        bind,
        max_conn: boot.max_conn,
        backlog: 4096,
    };
    let tls = httparena_sark::tls::config(vec![b"h2".to_vec()]);

    Launcher::new(boot.cpus.clone()).run(move |ctx: Ctx| {
        if h2_cpus.contains(&ctx.cpu) {
            sark_h2::server::serve_tls(
                httparena_sark::h2bench::BenchHandler::with_serve(serve).advertise_h3(true),
                h2_cfg.clone(),
                tls.clone(),
                ctx,
                None,
            )
        } else {
            run_thread(ctx, bind, serve)
        }
    })
}
