// The entry with TLS (app.goose): server.goose's listeners, and TLS 1.3 with
// TLS_CERT and TLS_KEY on 8081, for HTTP/1.1, and 8443, for h2 or HTTP/1.1 as
// ALPN chooses.
import std;
import os;
import http from "github.com/kaitk/goose-http@v0.5.8";
import compress from "github.com/kaitk/goose-compress@v0.1.4";
import tls from "github.com/kaitk/goose-tls@v0.0.5";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "github.com/kaitk/goose-postgres@v0.0.6";
import plod from "github.com/kaitk/plod@v0.5.4";
import plod.tls;
import app;

thread_fn worker(cfg: http::Config, ctx: tls::Context) {
    var server = http::tls_server(ctx);
    var app = App { db: pg::pool(db_cfg, per_worker) };
    let e = plod::serve(cfg, app, St { .. }, server) { cx => on_call(cx); };
    pg::close(app.db);
    http::release(server);
    if e.code != 0 { http::report(e); }
}

fn main() {
    http::exit_on_error(http::stop_on_signals());
    var cert: u8[>..] = [];
    var key: u8[>..] = [];
    guard env("TLS_CERT", cert) && env("TLS_KEY", key) else { abort("TLS_CERT and TLS_KEY name the certificate and key"); }
    let ctx, ok = tls::server_files(cert, key, ["h2", "http/1.1"]);
    guard ok else { abort(str("TLS_CERT and TLS_KEY: ", tls::error_text())); }
    load_dataset();
    var cfg = config();
    cfg.listeners.push(http::Listener { port: 8081, tls: true });
    cfg.listeners.push(http::Listener { port: 8443, tls: true });
    load_database(cfg);
    open_caches(cfg);
    http::run(cfg, ctx, worker);
    stop_caches();
}
