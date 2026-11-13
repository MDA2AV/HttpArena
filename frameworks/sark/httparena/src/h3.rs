use std::{cell::Cell, fmt::Debug, io, net::SocketAddr, num::NonZero, task::Poll};

use dope::{
    core::{
        driver::{
            result::SubmitCause,
            schedule::ready::wake::{Waker, store::Slot},
        },
        io::datagram::ReceiveError,
    },
    manifold::network::datagram::RejectCause,
};
use dope_quic::{
    conn::life::options,
    proto::{cid, param},
    runtime::{
        endpoint::{self, config},
        mux::{builder, handler::hook::wire::packet},
        receive, routing,
    },
    rustls::ServerConfig,
};
use o3::base::time::Positive;
use sark_h3::manifold::server::{self, failure, startup};

pub const ID: u8 = 6;

#[derive(Debug)]
pub enum Error {
    Random(getrandom::Error),
    Parameters(param::Error),
    Options(options::builder::Invalid),
    Endpoint(endpoint::PlanError),
    Application(server::ConfigError),
}

pub fn plan<'g>(
    binding: routing::Binding<'g>,
    tls: ServerConfig,
    max_connections: NonZero<usize>,
) -> Result<startup::Plan<'g, ID, receive::Retained, routing::Routed>, Error> {
    let params = param::Set::builder()
        .idle_ms(30_000)
        .initial_data(64 * 1024 * 1024)
        .local_bidi(1024 * 1024)
        .remote_bidi(1024 * 1024)
        .stream_uni(1024 * 1024)
        .bidi_count(256)
        .uni_count(16)
        .cid_limit(4)
        .try_build()
        .map_err(Error::Parameters)?;
    let mut secret = [0; 32];
    getrandom::fill(&mut secret).map_err(Error::Random)?;
    let options = options::Options::builder()
        .transport(|path| path.params(params))
        .security(|security| security.reset(Some(secret)))
        .try_build()
        .map_err(Error::Options)?;
    let capacity = builder::Plan::standard();
    let endpoint = config::Config {
        max_conns: max_connections.get(),
        outgoing_capacity: capacity.outgoing(),
        outgoing_bytes_capacity: capacity.bytes(),
        packet_buffer_slots: 256,
        packet_buffer_bytes: 2048,
        cid_rotation: cid::Rotation::from_nanos(
            NonZero::<u64>::MIN.saturating_add(59_999_999_999),
            NonZero::<u16>::MIN.saturating_add(63),
        ),
        opening_lifetime: Some(Positive::from_secs::<30>()),
    };
    let endpoint = endpoint::server::Plan::<ID>::routed(binding, tls, options, endpoint)
        .map_err(Error::Endpoint)?;
    startup::Plan::try_from(endpoint, server::Config::default()).map_err(Error::Application)
}

pub(crate) struct Signal<'d> {
    failure: Cell<Option<RejectCause>>,
    waiter: Slot<'d>,
}

impl<'d> Signal<'d> {
    pub(crate) const fn new() -> Self {
        Self {
            failure: Cell::new(None),
            waiter: Slot::empty(),
        }
    }

    pub(crate) fn poll(&self, waiter: Waker<'d>) -> Poll<RejectCause> {
        self.waiter.set(waiter);
        match self.error() {
            Some(error) => Poll::Ready(error),
            None => Poll::Pending,
        }
    }

    pub(crate) fn error(&self) -> Option<RejectCause> {
        self.failure.get()
    }

    pub(crate) fn detach(&self) {
        self.waiter.clear();
    }

    fn fail(&self, error: RejectCause) {
        self.failure.set(self.failure.get().or(Some(error)));
        self.waiter.wake_once();
    }
}

pub struct Report<'a, 'd> {
    diagnostics: &'a Cell<Option<io::Error>>,
    signal: &'a Signal<'d>,
}

impl<'a, 'd> Report<'a, 'd> {
    pub(crate) const fn new(
        diagnostics: &'a Cell<Option<io::Error>>,
        signal: &'a Signal<'d>,
    ) -> Self {
        Self {
            diagnostics,
            signal,
        }
    }
}

impl<C: Debug> failure::Sink<C> for Report<'_, '_> {
    fn failure(&mut self, event: failure::Event<'_, C>) {
        match &event {
            failure::Event::Receive(ReceiveError::Submit(error))
            | failure::Event::Submit(error)
                if error.cause() == SubmitCause::IdentityExhausted =>
            {
                self.signal.fail(RejectCause::Submit(*error));
            }
            failure::Event::Rejected(error) => self.signal.fail(*error),
            _ => crate::diagnostic(self.diagnostics, format_args!("h3: {event:?}")),
        }
    }
}

impl failure::Packet for Report<'_, '_> {
    fn packet(&mut self, from: SocketAddr, len: usize, error: packet::Failure<'_>) {
        crate::diagnostic(
            self.diagnostics,
            format_args!("h3: packet from {from}, {len} bytes: {error:?}"),
        );
    }
}
