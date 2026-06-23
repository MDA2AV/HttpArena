use std::io;
use std::marker::PhantomData;
use std::net::SocketAddr;

use dope::launcher::{Ctx, Launcher};
use dope::manifold::env::Bundle;
use dope::manifold::listener::{Listener, config};
use dope::runtime::profile::Production;
use dope::transport::Tcp;
use dope::wire::Identity;
use dope::{DriverConfig, Executor};
use dope_tls::{Endpoint, Tls};
use http::StatusCode;
use httparena_sark::boot::Boot;
use httparena_sark::json::JsonOut;
use o3::buffer::Owned;
use sark::date::{DateHost, Updater};
use sark::timer::{SARK_TIMER_ID, TimerHost};

#[sark_gen::response(raw)]
#[header("content-type", "text/plain")]
struct BaselineResponse {
    status: StatusCode,
    body: Owned,
}

#[sark_gen::request(ordered)]
struct BaselineGet {
    #[query("a", default = "0")]
    a: u64,
    #[query("b", default = "0")]
    b: u64,
}

#[sark_gen::handler]
fn baseline_get(req: BaselineGet, _state: &()) -> BaselineResponse {
    BaselineResponse {
        status: StatusCode::OK,
        body: JsonOut::sum_body(req.a, req.b),
    }
}

#[sark_gen::response(raw)]
#[header("content-type", "application/json")]
struct JsonResponse {
    status: StatusCode,
    body: Owned,
}

#[sark_gen::request(ordered)]
struct JsonRequest {
    #[path("count", default = "1")]
    count: u64,
    #[query("m", default = "1")]
    m: u64,
}

#[sark_gen::handler]
fn json_endpoint(req: JsonRequest, _state: &()) -> JsonResponse {
    JsonResponse {
        status: StatusCode::OK,
        body: JsonOut::items_standard(req.count as usize, req.m),
    }
}

sark_gen::define_route! {
    TlsApp: () => {
        GET "/baseline2" => baseline_get,
        GET "/json/:count" => json_endpoint,
    }
}

type IdEnv = Bundle<Tcp, Identity, Production>;
type TlsEnv = Bundle<Tcp, Tls, Production>;

#[pin_project::pin_project(!Unpin)]
#[derive(dope_gen::Dispatcher)]
struct Dispatcher<'d, RA, TA>
where
    RA: dope::manifold::listener::Application<Wire = Identity> + DateHost + TimerHost<'d>,
    TA: dope::manifold::listener::Application<Wire = Tls> + DateHost + TimerHost<'d>,
{
    #[pin]
    #[manifold(optional)]
    readiness: Option<Listener<1, RA, IdEnv>>,
    #[pin]
    #[manifold(optional)]
    tls: Option<Listener<0, TA, TlsEnv>>,
    #[pin]
    #[manifold]
    date: Updater<2>,
    #[pin]
    #[manifold]
    timer: dope::manifold::timer::Timer<{ SARK_TIMER_ID }>,
    _ph: PhantomData<&'d ()>,
}

fn listener_cfg(bind: SocketAddr, max_conn: usize) -> config::Config<Tcp> {
    config::Config::<Tcp> {
        max_conn,
        bind,
        backlog: 4096,
        stream_opts: Default::default(),
        listener_opts: dope::transport::config::tcp::ListenerOpts {
            reuseport: dope::transport::config::SocketToggle::Enabled,
            per_ip_cap: Some((max_conn / 2) as u32),
            ..Default::default()
        },
    }
}

fn run_thread(
    ctx: Ctx,
    tls_bind: SocketAddr,
    ready_bind: SocketAddr,
    max_conn: usize,
) -> io::Result<()> {
    let driver_cfg = <dope::DriverCfg as DriverConfig>::for_tcp_profile::<Production>(max_conn)
        .with_cpu_id(Some(ctx.cpu));
    let mut exec = Executor::new(driver_cfg)?;

    let mut app = core::pin::pin!(Dispatcher::<'_, _, _> {
        readiness: None::<Listener<1, _, IdEnv>>,
        tls: None::<Listener<0, _, TlsEnv>>,
        date: Updater::<2>::new(),
        timer: dope::manifold::timer::Timer::new(),
        _ph: PhantomData,
    });
    let timer_borrow = app.as_mut().timer_handle();

    let readiness = {
        let drv = exec.driver_mut();
        Listener::<1, _, IdEnv>::open_in(
            tls_app::new::<Identity>(&()),
            listener_cfg(ready_bind, max_conn),
            drv,
        )?
    };
    let mut tls = {
        let drv = exec.driver_mut();
        Listener::<0, _, TlsEnv>::open_in(
            tls_app::new::<Tls>(&()),
            listener_cfg(tls_bind, max_conn),
            drv,
        )?
    };
    tls.set_cfg(Endpoint::Server(Box::new(httparena_sark::tls::config(vec![
        b"http/1.1".to_vec(),
    ]))));
    let stamp = {
        let handler = tls.handler_mut();
        handler.bind_timer(timer_borrow);
        std::ptr::NonNull::from(handler.date_stamp())
    };
    let mut init = app.as_mut().project();
    init.date.as_mut().get_mut().bind(stamp);
    init.readiness.set(Some(readiness));
    init.tls.set(Some(tls));
    exec.run(app.as_mut())
}

fn main() -> io::Result<()> {
    let boot = Boot::from_env(8081);
    let tls_bind = boot.bind;
    let ready_bind = SocketAddr::from(([0, 0, 0, 0], 8080));
    let max_conn = boot.max_conn;
    Launcher::new(boot.cpus).run(|ctx: Ctx| run_thread(ctx, tls_bind, ready_bind, max_conn))
}
