//! Per-CPU current_thread tokio runtimes with SO_REUSEPORT TCP listeners.
//!
//! Each worker OS thread:
//! 1. Builds a `current_thread` tokio runtime.
//! 2. Creates one `socket2::Socket` per port (8080, optionally 8081/8443) with `SO_REUSEPORT` +
//!    `SO_REUSEADDR` + `TCP_NODELAY`, binds it to the same address as every other worker, and
//!    converts to `tokio::net::TcpListener`.
//! 3. Hands each listener to a `trillium_tokio::config().with_prebound_server(...)`.
//! 4. Awaits a shared `Swansong` to coordinate graceful shutdown.
//!
//! The kernel's SO_REUSEPORT load-balancer hashes incoming SYNs across listeners by 4-tuple,
//! so connections fan out across workers without any user-space dispatch hop.
//!
//! Worker 0 additionally binds the QUIC endpoint (single endpoint, not sharded — see comments
//! in main.rs).

use socket2::{Domain, SockAddr, Socket, Type};
use std::{
    io,
    net::{Ipv4Addr, SocketAddr},
};
use trillium_tokio::tokio::net::TcpListener;

const LISTEN_BACKLOG: i32 = 4096;

/// Build a fresh TCP listener with SO_REUSEPORT, SO_REUSEADDR, and TCP_NODELAY,
/// bound to `0.0.0.0:port` and ready for tokio.
pub fn bind_reuseport(port: u16) -> io::Result<TcpListener> {
    let addr = SocketAddr::from((Ipv4Addr::UNSPECIFIED, port));
    let socket = Socket::new(Domain::IPV4, Type::STREAM, None)?;

    #[cfg(unix)]
    socket.set_reuse_port(true)?;
    socket.set_reuse_address(true)?;
    socket.set_nodelay(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&SockAddr::from(addr))?;
    socket.listen(LISTEN_BACKLOG)?;

    let std_listener: std::net::TcpListener = socket.into();
    TcpListener::from_std(std_listener)
}
