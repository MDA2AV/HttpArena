// The entry without TLS (app.goose), for the profiles on 8080 and 8082, and
// behind the gateway profiles' proxies, which reach it on PROXY_PORT as well:
// on the host network, the entry's own container can hold 8080 meanwhile.
import std;
import os;
import http from "github.com/kaitk/goose-http@v0.5.9";
import compress from "github.com/kaitk/goose-compress@v0.1.4";
import hash from "github.com/kaitk/goose-hash@v0.0.4";
import pg from "github.com/kaitk/goose-postgres@v0.0.6";
import plod from "github.com/kaitk/plod@v0.5.6";
import app;

thread_fn worker(cfg: http::Config) {
    var app = App { db: pg::pool(db_cfg, per_worker) };
    let e = plod::serve(cfg, app, St { .. }) { cx => on_call(cx); };
    pg::close(app.db);
    if e.code != 0 { http::report(e); }
}

fn main() {
    http::exit_on_error(http::stop_on_signals());
    load_dataset();
    var cfg = config();
    var port: u8[>..] = [];
    if env("PROXY_PORT", port) {
        let p, ok = parse_int(trim(port));
        guard ok else { abort("PROXY_PORT: not a port"); }
        cfg.listeners.push(http::Listener { port: p as i32 });
    }
    load_database(cfg);
    open_caches(cfg);
    http::run(cfg, worker);
    stop_caches();
}
