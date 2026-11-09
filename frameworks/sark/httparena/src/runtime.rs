use std::{
    cell::Cell, convert::Infallible, fmt::Debug, marker::PhantomData, net::SocketAddr,
    num::NonZero, ops::ControlFlow, process::ExitCode, sync::Arc, task::Poll, time::Duration,
};

use crate::{App, State, boot::Boot, cache, dataset::Dataset, db, fail, files, tls};
use dope::{
    core::driver::{
        self,
        life::recovery,
        route::{KeyTag, table::conn},
        schedule::ready::wake,
        settings::{self, claim},
        storage,
    },
    core::io::socket::{self, option::Switch},
    manifold::{
        app::{
            env::{Bundle, quota::PerIp},
            receive::limits::Budget,
        },
        file::read,
        network::{
            datagram::RejectCause,
            listener::{AcceptError, Wait, Watch, config, handler},
        },
        service,
        timing::Throughput,
    },
    net::{
        tcp::{self, Tcp},
        wire::{self, Identity, domain},
    },
    runtime::{
        client,
        executor::{self, drive, root, session},
        shutdown,
        topology::{self, lending},
    },
};
use dope_fiber::task::storage::scope::Brand;
use dope_quic::runtime::mux::app::Silent;
use dope_tls::tls::{Tls, endpoint, roles};
use o3::{base::time::Positive, buffer::hold::limits::Bound};
use sark::core::{deadline, life};
use sark_grpc::server::{Bank, config::Limits, mode};
use sark_h1::server::{date, listener};
use sark_h2::{
    conn::config::{self as h2_config, capacity::Payload},
    server::{self as h2, runtime::app::Failure},
};
use sark_h3::manifold::server as h3;

const FILE_ROUTE: u8 = 12;
const H2_STREAMS: NonZero<usize> = NonZero::<usize>::MIN.saturating_add(255);
const H2_CONFIG: h2::Config = h2::Config {
    max_request_body_bytes: 32 << 20,
    max_request_body_chunks: h2::DEFAULT_MAX_REQUEST_BODY_CHUNKS,
    max_connection_body_bytes: 64 << 20,
    max_connection_body_chunks: h2::DEFAULT_MAX_CONNECTION_BODY_CHUNKS,
    max_outbound_bytes: 64 << 10,
};

pub struct Worker<'g> {
    pub boot: Boot,
    pub connections: NonZero<usize>,
    pub tcp_connections: NonZero<usize>,
    pub database_connections: NonZero<usize>,
    pub h3: Option<dope_quic::runtime::routing::Binding<'g>>,
}

#[derive(Default)]
pub struct Bindings {
    pub http: Option<dope::core::io::socket::Listener>,
    pub https: Option<dope::core::io::socket::Listener>,
    pub h2c: Option<dope::core::io::socket::Listener>,
    pub h2: Option<dope::core::io::socket::Listener>,
}

struct FilePlan {
    reader: read::Layout<KeyTag<FILE_ROUTE>>,
    bytes: usize,
}

impl settings::Resource for FilePlan {
    fn include_in(&self, needs: claim::Needs) -> Result<claim::Needs, settings::errors::Claim> {
        self.reader
            .include_in(needs)?
            .include(claim::Claim::new(settings::Routes::EMPTY).domains(settings::Domain::ONE))
    }
}

#[pin_project::pin_project]
#[derive(dope::Application)]
#[dispatcher(driver = 'd)]
struct Server<'files, 'd, A> {
    #[pin]
    #[app]
    http: A,
    #[pin]
    #[manifold]
    files: read::Reader<'files, 'd, KeyTag<FILE_ROUTE>>,
}

#[pin_project::pin_project]
#[derive(dope::Application)]
#[dispatcher(driver = 'd)]
struct Protocols<'d, A, B, C, D, E> {
    #[pin]
    #[app]
    http: A,
    #[pin]
    #[app]
    tls: B,
    #[pin]
    #[manifold]
    h2c: C,
    #[pin]
    #[manifold]
    h2: D,
    #[pin]
    #[manifold]
    h3: E,
    #[dispatcher(state)]
    domain: PhantomData<driver::Reference<'d>>,
}

struct Waits<'a, 'h3, 'd, const N: usize> {
    listeners: [(u8, Wait<'a, 'd>); N],
    h3: Option<&'h3 crate::h3::Signal<'d>>,
}

impl<const N: usize> Drop for Waits<'_, '_, '_, N> {
    fn drop(&mut self) {
        if let Some(h3) = self.h3 {
            h3.detach();
        }
    }
}

#[derive(Debug)]
enum Stop {
    Listener { route: u8, cause: AcceptError },
    Quic(RejectCause),
}

impl<'d, const N: usize> root::Root<'d> for Waits<'_, '_, 'd, N> {
    type Output = Stop;

    fn poll(context: root::Context<'_, 'd, Self>) -> Poll<Self::Output> {
        let (waits, target, _, _) = context.into_parts();
        let waits = waits.get_mut();
        if let Some(h3) = waits.h3 {
            if let Poll::Ready(cause) = h3.poll(wake::Waker::from(target)) {
                return Poll::Ready(Stop::Quic(cause));
            }
        }
        for (route, wait) in &mut waits.listeners {
            if let Poll::Ready(cause) = wait.poll(wake::Waker::from(target)) {
                return Poll::Ready(Stop::Listener {
                    route: *route,
                    cause,
                });
            }
        }
        Poll::Pending
    }
}

type Driven<Q> = Result<ControlFlow<Stop, shutdown::Requested<Q>>, drive::Error>;

fn finish<Q>(
    result: lending::Result<'_, ExitCode, Driven<Q>>,
    watches: &[(u8, &Watch<'_>)],
    quic: Option<RejectCause>,
) -> Result<shutdown::Requested<Q>, ExitCode> {
    let mut failed = None;
    for (route, watch) in watches {
        if let Some(cause) = watch.error() {
            let status = fail(format_args!("listener {route}: {cause:?}"));
            if failed != Some(ExitCode::from(2)) {
                failed = Some(status);
            }
        }
    }
    if let Some(cause) = quic {
        let status = fail(format_args!("HTTP/3 endpoint: {cause:?}"));
        if failed != Some(ExitCode::from(2)) {
            failed = Some(status);
        }
    }
    let result = match result {
        Ok(Ok(ControlFlow::Continue(requested))) => match failed {
            Some(status) => Err(status),
            None => Ok(requested),
        },
        Ok(Ok(ControlFlow::Break(cause))) => Err(failed.unwrap_or_else(|| match cause {
            Stop::Listener { route, cause } => fail(format_args!("listener {route}: {cause:?}")),
            Stop::Quic(cause) => fail(format_args!("HTTP/3 endpoint: {cause:?}")),
        })),
        Ok(Err(cause)) => Err(fail(format_args!("worker drive: {cause:?}"))),
        Err(lending::Error::Build(status)) => Err(status),
        Err(lending::Error::Run(cause)) => Err(fail(format_args!(
            "worker session: {:?}, output: {:?}",
            cause.cause(),
            cause.output().and_then(|output| output.as_ref().err()),
        ))),
    };
    if failed == Some(ExitCode::from(2)) {
        Err(ExitCode::from(2))
    } else {
        result
    }
}

fn recover(failure: recovery::Recovery<'_, '_>) -> Infallible {
    let _ = fail(format_args!("native recovery: {:?}", failure.cause()));
    failure.abort()
}

fn snapshot(
    address: Option<std::net::SocketAddr>,
) -> service::Snapshot<service::Endpoint<std::net::SocketAddr, std::net::SocketAddr>> {
    let revision = service::Revision::new(1);
    match address {
        Some(address) => {
            service::Snapshot::from_one(revision, service::Endpoint::new(address, address))
        }
        None => service::Snapshot::empty(revision),
    }
}

fn tcp_config(bind: SocketAddr, capacity: conn::Capacity) -> config::Prepared<Tcp> {
    config::Prepared {
        bind,
        connections: capacity,
        per_ip: Some(PerIp::UNLIMITED),
        direct_flights: config::Flights::Exact(capacity.nonzero().get()),
        backlog: socket::Backlog::fixed::<1024>(),
        stream: tcp::StreamConfig {
            no_delay: Some(Switch::On),
            ..Default::default()
        },
        transport: tcp::Config::for_tcp(Some(socket::Reuse::Port), None),
        egress: Default::default(),
    }
}

fn h2_plan<const ID: u8>(
    bind: SocketAddr,
    capacity: conn::Capacity,
    bound: Option<socket::Listener>,
    protocol: h2_config::Config,
) -> Result<h2::runtime::Plan<KeyTag<ID>>, ExitCode> {
    let plan = h2::runtime::Plan::new(
        tcp_config(bind, capacity),
        <Throughput as settings::Profile>::RECEIVE,
        H2_CONFIG,
    )
    .map_err(|cause| fail(format_args!("HTTP/2 topology: {cause:?}")))?
    .with_config(protocol)
    .with_life(handler::Lifetime::graceful(
        Positive::from_secs::<300>(),
        Positive::from_secs::<10>(),
    ));
    Ok(match bound {
        Some(bound) => plan.with_bound(bound),
        None => plan,
    })
}

fn h2_report<'w, 'd: 'w, W, ID, E: Debug, B: Debug>(
    diagnostics: &Cell<Option<std::io::Error>>,
    failure: Failure<'_, 'w, 'd, W, ID, E, B>,
) where
    W: wire::Spec + 'w,
    ID: driver::route::Identity,
    <W::OpenFailure as wire::failure::Class<W, wire::failure::Open>>::Error<'w>: Debug,
    <W::TerminalFailure as wire::failure::Class<W, wire::failure::Terminal>>::Error<'w>: Debug,
{
    let route = ID::ID.raw();
    match failure {
        Failure::Construction(cause) => crate::diagnostic(
            diagnostics,
            format_args!("HTTP/2 listener {route} construction: {cause:?}"),
        ),
        Failure::Drive { id, cause } | Failure::Diagnostic { id, cause } => crate::diagnostic(
            diagnostics,
            format_args!(
                "HTTP/2 listener {route} connection {}: {cause:?}",
                id.index().get()
            ),
        ),
        Failure::Output { id, cause } => crate::diagnostic(
            diagnostics,
            format_args!(
                "HTTP/2 listener {route} output {}: {cause:?}",
                id.index().get()
            ),
        ),
        Failure::Response { id, stream, cause } => crate::diagnostic(
            diagnostics,
            format_args!(
                "HTTP/2 listener {route} response {} {stream:?}: {cause:?}",
                id.index().get()
            ),
        ),
        Failure::Open(cause) => crate::diagnostic(
            diagnostics,
            format_args!("HTTP/2 listener {route} open: {:?}", cause.into_cause()),
        ),
        Failure::Wire { id, cause } => {
            let (cause, closing) = cause.into_parts();
            crate::diagnostic(
                diagnostics,
                format_args!(
                    "HTTP/2 listener {route} wire {}: {cause:?}, closing: {closing:?}",
                    id.index().get()
                ),
            );
        }
    }
}

pub fn serve<C: executor::Build>(
    input: Worker<'_>,
    context: C,
    bindings: Bindings,
) -> Result<shutdown::Requested<C::Shutdown>, ExitCode> {
    let Worker {
        boot,
        connections,
        tcp_connections,
        database_connections,
        h3,
    } = input;
    let application_tasks = connections
        .checked_mul(if h3.is_some() {
            NonZero::<usize>::MIN.saturating_add(4)
        } else {
            NonZero::<usize>::MIN
        })
        .ok_or_else(|| fail(format_args!("application task capacity overflow")))?;
    let capacity = conn::Capacity::try_from(tcp_connections.get())
        .map_err(|cause| fail(format_args!("HTTP connection capacity: {cause:?}")))?;
    let [bind, tls_bind, h2c_bind, h2_bind] = boot.tcp_bind;
    let tasks = sark_fiber::Config::new(connections.get());
    let http_tasks = tasks.with_budget(Budget::new(
        Bound::new(
            <Throughput as settings::Profile>::RECEIVE
                .buffer_len()
                .widen()
                .get(),
        ),
        0,
    ));
    let dataset =
        Dataset::load(&boot.dataset).map_err(|cause| fail(format_args!("dataset: {cause:?}")))?;
    let cache_tokens =
        cache::Tokens::new().map_err(|cause| fail(format_args!("cache tokens: {cause:?}")))?;
    let (pg_address, pg_auth) = boot
        .postgres()
        .map_err(|cause| fail(format_args!("PostgreSQL input: {cause:?}")))?;
    let pg_configured = pg_address.is_some();
    let database_connections =
        database_connections.min(NonZero::<usize>::MIN.saturating_add(db::TASKS - 1));
    let pg_limits = db::pg_config(database_connections, application_tasks, pg_configured)
        .map_err(|cause| fail(format_args!("PostgreSQL capacity: {cause:?}")))?;
    let (_, pg) = cartel_pg::port::Port::<db::Db, { db::ID }>::plan(pg_auth, pg_limits)
        .assemble::<Bundle<Tcp, Identity, Throughput>>(
            snapshot(pg_address),
            Duration::from_millis(500),
            Duration::from_secs(30),
        )
        .map_err(|cause| fail(format_args!("PostgreSQL topology: {cause:?}")))?
        .into_parts();
    let (redis_address, redis_init) = boot
        .redis()
        .map_err(|cause| fail(format_args!("Redis input: {cause:?}")))?;
    let redis_configured = redis_address.is_some();
    let redis_limits = cache::config(application_tasks, redis_configured)
        .map_err(|cause| fail(format_args!("Redis capacity: {cause:?}")))?;
    let (_, redis) = cartel_redis::client::plan::Plan::<{ cache::ID }>::new(redis_limits)
        .assemble::<Bundle<Tcp, Identity, Throughput>>(
            snapshot(redis_address),
            Duration::from_millis(500),
            Duration::from_secs(30),
            redis_init,
        )
        .map_err(|cause| fail(format_args!("Redis topology: {cause:?}")))?
        .into_parts();
    let http = listener::Config::<KeyTag<0>, Throughput>::new(
        tcp_config(bind, capacity),
        Duration::from_secs(30),
    )
    .plan::<KeyTag<1>>()
    .gated_scoped();
    let http = match bindings.http {
        Some(bound) => http.with_bound(bound),
        None => http,
    };
    let secure = if let Some(h3) = h3 {
        let mut config = tls::config(&boot.certificate, &boot.private_key)
            .map_err(|cause| fail(format_args!("TLS configuration: {cause:?}")))?;
        let grpc_limits = Limits::default()
            .try_calls(H2_STREAMS.get())
            .map_err(|cause| fail(format_args!("gRPC call capacity: {cause:?}")))?;
        let protocol = h2_config::Config {
            stream_capacity: H2_STREAMS.get(),
            event_capacity: 64,
            payload_capacity: Payload::new(64, H2_STREAMS.get() + 1)
                .map_err(|cause| fail(format_args!("HTTP/2 payload capacity: {cause:?}")))?,
            ..Default::default()
        };
        let cleartext = h2::Plan::new(H2_CONFIG, <Throughput as settings::Profile>::RECEIVE)
            .map_err(|cause| fail(format_args!("cleartext H2 limits: {cause:?}")))?
            .with_config(protocol);
        let mut h2_config = config.clone();
        let mut h3_config = config.clone();
        config.alpn_protocols = vec![b"http/1.1".to_vec()];
        h2_config.alpn_protocols = vec![b"h2".to_vec()];
        h3_config.alpn_protocols = vec![b"h3".to_vec()];
        let http = listener::Config::<KeyTag<2>, Throughput>::new(
            tcp_config(tls_bind, capacity),
            Duration::from_secs(30),
        )
        .plan::<KeyTag<3>>()
        .gated_scoped();
        let http = match bindings.https {
            Some(bound) => http.with_bound(bound),
            None => http,
        };
        let owner = http
            .owner::<Tls<roles::Server>>()
            .map_err(|cause| fail(format_args!("TLS wire storage: {cause:?}")))?;
        let h2c = h2_plan::<4>(h2c_bind, capacity, bindings.h2c, protocol)?;
        let h2 = h2_plan::<8>(h2_bind, capacity, bindings.h2, protocol)?;
        let h2_owner = domain::Owner::<Tls<roles::Server>, KeyTag<8>>::try_new(capacity)
            .map_err(|cause| fail(format_args!("HTTP/2 TLS wire storage: {cause:?}")))?;
        let h3 = crate::h3::plan(h3, h3_config, connections)
            .map_err(|cause| fail(format_args!("HTTP/3 topology: {cause:?}")))?;
        Some((
            (http, h2c, h2, h3),
            (owner, h2_owner),
            (
                endpoint::Config::from(Arc::new(config)).with_growth(NonZero::<u32>::MIN),
                endpoint::Config::from(Arc::new(h2_config)).with_growth(NonZero::<u32>::MIN),
                cleartext,
                grpc_limits,
            ),
        ))
    } else {
        None
    };
    let (secure, tls_owner, protocol_config) = match secure {
        Some((plans, owners, wires)) => (Some(plans), Some(owners), Some(wires)),
        None => (None, None, None),
    };
    let file_operations = NonZero::<u32>::try_from(connections)
        .map_err(|cause| fail(format_args!("file operation capacity: {cause:?}")))?;
    let file_bytes = connections
        .get()
        .checked_mul(files::CHUNK_BYTES * 2)
        .ok_or_else(|| fail(format_args!("file resident capacity overflow")))?;
    let file_layout = FilePlan {
        reader: read::Layout::<KeyTag<FILE_ROUTE>>::try_new(file_operations)
            .map_err(|cause| fail(format_args!("file capacity: {cause:?}")))?,
        bytes: file_bytes,
    };
    let clock = date::Clock::new().map_err(|cause| fail(format_args!("HTTP date: {cause:?}")))?;
    let storage = storage::With::new(storage::Value::new(tls_owner), clock);
    let timers = settings::demands::slots::Slots::try_from(application_tasks.get())
        .map_err(|cause| fail(format_args!("application timer capacity: {cause:?}")))?;
    let config = claim::Needs::from_tree(&(&pg, &redis))
        .and_then(|needs| {
            needs.include(claim::Claim::new(settings::Routes::EMPTY).schedule(
                settings::Schedule::new(settings::demands::slots::Slots::ZERO, timers),
            ))
        })
        .and_then(|needs| needs.apply_to(http.config()))
        .map_err(|cause| fail(format_args!("application resource layout: {cause:?}")))?;
    let prepared = topology::Plan::new(storage, (http, secure, pg, redis, file_layout))
        .with_install(config)
        .map_err(|cause| fail(format_args!("worker resource layout: {cause:?}")))?;
    let mut completion = session::Completion::new();
    let diagnostics = Cell::new(None);
    let result = prepared.enter_with(
        context,
        |worker| worker.lend(|(http, secure, pg, redis, file_layout), stage| {
            let h3_signal = crate::h3::Signal::new();
            let port = file_layout.reader.try_port()
                .map_err(|cause| fail(format_args!("file port: {cause:?}")))?;
            let budget = stage.driver().storage.budget(storage::Resident::bytes(file_layout.bytes))
                .map_err(|cause| fail(format_args!("file resident budget: {cause:?}")))?;
            let files = files::Root::try_new(&boot.static_root, &port, budget)
                .map_err(|cause| fail(format_args!("static root: {cause:?}")))?;
            drop(boot);
            pg.install(stage, |pg, stage| {
                redis.install(stage, |redis, stage| {
                    stage.hold(client::Pair::new(pg, redis), |held, stage| {
                        http.prepare_in(stage, domain::Local::new(Identity), |prepared, wait, stage| {
                            let watch = wait.watch();
                            match secure {
                                None => Brand::with(|brand| {
                                    let result = held.lend_scope(stage, &mut completion, |issued| {
                                        let ((pg, redis), permit) = issued.into_parts();
                                        let state = std::pin::pin!(State {
                                            pg, redis, pg_configured, redis_configured,
                                            dataset: &dataset, files, cache_tokens, diagnostics: &diagnostics,
                                        });
                                        let state = state.as_ref().get_ref();
                                        let port = &port;
                                        permit.try_run(
                                            move |mut driver| {
                                                let app = App::new::<_, _, Identity, KeyTag<0>>(
                                                    brand, state, http_tasks,
                                                );
                                                let http = prepared.build(app, &mut driver)
                                                    .map_err(|cause| fail(format_args!("HTTP installation: {cause:?}")))?;
                                                let files = read::Reader::try_new(port, &mut driver)
                                                    .map_err(|cause| fail(format_args!("file reader: {cause:?}")))?;
                                                Ok((Server { http, files }, Waits { listeners: [(0, wait)], h3: None }))
                                            },
                                            |waits, app| app.drive_until(waits),
                                        )
                                    });
                                    finish(result, &[(0, watch)], None)
                                }),
                                Some((https, h2c, h2, h3_plan)) => {
                                    let (Some((owner, h2_owner)), Some((wire, h2_wire, cleartext_plan, grpc_limits))) = (&stage.storage().0, protocol_config) else {
                                        unreachable!("tls")
                                    };
                                    let bank = Bank::try_new(capacity.count(), grpc_limits)
                                        .map_err(|cause| fail(format_args!("gRPC storage: {cause:?}")))?;
                                    let cleartext_bank = Bank::try_new(capacity.count(), grpc_limits)
                                        .map_err(|cause| fail(format_args!("cleartext gRPC storage: {cause:?}")))?;
                                    let (bank, cleartext_bank) = (&bank, &cleartext_bank);
                                    let wire = owner.bind(wire)
                                        .map_err(|cause| fail(format_args!("TLS wire binding: {cause:?}")))?;
                                    let h2_wire = h2_owner.bind(h2_wire)
                                        .map_err(|cause| fail(format_args!("HTTP/2 TLS wire binding: {cause:?}")))?;
                                    https.prepare_in(stage, wire, |tls_prepared, tls_wait, stage| {
                                        let tls_watch = tls_wait.watch();
                                        h2c.tasks((), connections.get()).report(
                                            |failure: Failure<'_, '_, '_, Identity, KeyTag<4>, Infallible, h2::task::Build>| {
                                                h2_report(&diagnostics, failure);
                                            },
                                        ).prepare_in::<Identity, _, _, _, _, _, _>(
                                            stage, domain::Local::new(Identity), |h2c_prepared, h2c_wait, stage| {
                                                let h2c_watch = h2c_wait.watch();
                                                h2.tasks((), connections.get()).report(
                                                    |failure: Failure<
                                                        '_, '_, '_, Tls<roles::Server>, KeyTag<8>,
                                                        sark_grpc::server::runtime::run::Failure,
                                                        h2::task::Build<sark_grpc::server::runtime::state::Error>,
                                                    >| h2_report(&diagnostics, failure),
                                                ).prepare_in::<Tls<roles::Server>, _, _, _, _, _, _>(
                                                    stage, h2_wire, |h2_prepared, h2_wait, stage| {
                                                        let h2_watch = h2_wait.watch();
                                                        Brand::with(|http_brand| Brand::with(|tls_brand| Brand::with(|h2c_brand| Brand::with(|h2_brand| Brand::with(|h3_brand| {
                                                            let result = held.lend_scope(stage, &mut completion, |issued| {
                                                                let ((pg, redis), permit) = issued.into_parts();
                                                                let state = std::pin::pin!(State {
                                                                    pg, redis, pg_configured, redis_configured,
                                                                    dataset: &dataset, files, cache_tokens, diagnostics: &diagnostics,
                                                                });
                                                                let state = state.as_ref().get_ref();
                                                                let port = &port;
                                                                let diagnostics = &diagnostics;
                                                                let h3_signal = &h3_signal;
                                                                permit.try_run(
                                                                    move |mut driver| {
                                                                        let cleartext = h2::runtime::app::App::new(
                                                                            mode::Direct.build(crate::grpcbench::BenchSvc, cleartext_bank),
                                                                            cleartext_plan,
                                                                            h2::runtime::app::Report::new(
                                                                                |failure: Failure<
                                                                                    '_, '_, '_, Identity, KeyTag<0>,
                                                                                    sark_grpc::server::runtime::run::Failure,
                                                                                    h2::runtime::Build<sark_grpc::server::runtime::state::Error>,
                                                                                >| h2_report(diagnostics, failure),
                                                                            ),
                                                                        ).map_err(|cause| fail(format_args!("cleartext H2 application: {cause:?}")))?;
                                                                        let http = App::cleartext_prepared(
                                                                            http_brand, state, http_tasks, prepared, cleartext, &mut driver,
                                                                        ).map_err(|cause| fail(format_args!("HTTP installation: {cause:?}")))?;
                                                                        let tls = tls_prepared.build(
                                                                            App::new::<_, _, Tls<roles::Server>, KeyTag<2>>(tls_brand, state, http_tasks),
                                                                            &mut driver,
                                                                        ).map_err(|cause| fail(format_args!("HTTPS installation: {cause:?}")))?;
                                                                        let lifetime = life::session::Config::new(
                                                                            Positive::from_secs::<300>(), Positive::from_secs::<10>(),
                                                                        );
                                                                        let deadline = deadline::config::Config::new(
                                                                            deadline::Phase::Total, Positive::from_secs::<30>(),
                                                                        );
                                                                        let h2c = h2c_prepared.build(
                                                                            App::multiplexed::<_, _, Identity, KeyTag<4>, _>(h2c_brand, state, tasks),
                                                                            deadline, &mut driver,
                                                                        ).map_err(|cause| fail(format_args!("H2C installation: {cause:?}")))?;
                                                                        let h2 = h2_prepared.build_with(
                                                                            App::multiplexed::<_, _, Tls<roles::Server>, KeyTag<8>, _>(h2_brand, state, tasks),
                                                                            deadline, mode::Direct.build(crate::grpcbench::BenchSvc, bank), &mut driver,
                                                                        ).map_err(|cause| fail(format_args!("HTTP/2 TLS installation: {cause:?}")))?;
                                                                        let h3 = h3_plan.try_with::<Silent, _, _, _, _, _>(
                                                                            App::multiplexed::<_, _, Identity, KeyTag<6>, h3::Handle<'_, 6>>(
                                                                                h3_brand, state, tasks,
                                                                            ),
                                                                            h3::failure::Quiet::new(crate::h3::Report::new(diagnostics, h3_signal)),
                                                                            lifetime, deadline, h3::Tasks::new(), &mut driver,
                                                                        ).map_err(|cause| fail(format_args!("HTTP/3 installation: {cause:?}")))?;
                                                                        let files = read::Reader::try_new(port, &mut driver)
                                                                            .map_err(|cause| fail(format_args!("file reader: {cause:?}")))?;
                                                                        let http = Protocols { http, tls, h2c, h2, h3, domain: PhantomData };
                                                                        Ok((Server { http, files }, Waits {
                                                                            listeners: [(0, wait), (2, tls_wait), (4, h2c_wait), (8, h2_wait)],
                                                                            h3: Some(h3_signal),
                                                                        }))
                                                                    },
                                                                    |waits, app| app.drive_until(waits),
                                                                )
                                                            });
                                                            finish(result, &[(0, watch), (2, tls_watch), (4, h2c_watch), (8, h2_watch)], h3_signal.error())
                                                        })))))
                                                    },
                                                ).map_err(|cause| fail(format_args!("HTTP/2 TLS storage: {cause:?}")))?
                                            },
                                        ).map_err(|cause| fail(format_args!("H2C storage: {cause:?}")))?
                                    }).map_err(|cause| fail(format_args!("HTTPS storage: {cause:?}")))?
                                }
                            }
                        }).map_err(|cause| fail(format_args!("HTTP storage: {cause:?}")))?
                    })
                }).map_err(|cause| fail(format_args!("Redis installation: {cause:?}")))?
            }).map_err(|cause| fail(format_args!("PostgreSQL installation: {cause:?}")))?
        }),
        recovery::Policy::new(
            |report| {
                crate::diagnostic(&diagnostics, format_args!("native completion: {report:?}"));
            },
            recover,
        ),
        |outcome| outcome.map_err(|cause| {
            let output = cause.output().and_then(|output| output.as_ref().err());
            let status = fail(format_args!(
                "worker domain: {:?}, output: {output:?}",
                cause.cause(),
            ));
            if output == Some(&ExitCode::from(2)) {
                ExitCode::from(2)
            } else {
                status
            }
        })?,
    );
    match diagnostics.take() {
        Some(cause) => {
            let _ = fail(format_args!("diagnostic output: {cause:?}"));
            Err(ExitCode::from(2))
        }
        None => result,
    }
}
