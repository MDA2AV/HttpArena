use std::cell::Cell;

use dope::Driver;
use dope::manifold::Outcome;
use dope::manifold::listener::recv::ExtendOutcome;
use dope::manifold::listener::{Application, Aux, State};
use dope::transport::link::Slot;
use dope::transport::wire::{Identity, RecvChunk};
use sark::date::{DateHost, Stamp};
use sark::dispatch::H1Project;
use sark::dispatch::conn_state::ConnState as H1ConnState;
use sark::timer::{Timer, TimerHost};
use sark_grpc::server::{App as GrpcApp, ConnState as GrpcConnState, Handler as GrpcHandler};
use sark_ws::server::{App as WsApp, ConnState as WsConnState, Handler as WsHandler};

use crate::demux::sniff;

#[allow(clippy::large_enum_variant)]
pub enum Demux8080Conn {
    Undecided(Vec<u8>),
    H1(H1ConnState),
    Ws(WsConnState),
    Grpc(GrpcConnState),
}

impl Default for Demux8080Conn {
    fn default() -> Self {
        Demux8080Conn::Undecided(Vec::new())
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Lane {
    Undecided,
    H1,
    Ws,
    Grpc,
}

pub(crate) fn lane_of(conn: &Demux8080Conn) -> Lane {
    match conn {
        Demux8080Conn::Undecided(_) => Lane::Undecided,
        Demux8080Conn::H1(_) => Lane::H1,
        Demux8080Conn::Ws(_) => Lane::Ws,
        Demux8080Conn::Grpc(_) => Lane::Grpc,
    }
}

pub(crate) fn take_buffer(conn: &mut Demux8080Conn) -> Vec<u8> {
    match std::mem::take(conn) {
        Demux8080Conn::Undecided(buf) => buf,
        _ => unreachable!(),
    }
}

fn proj_h1(conn: &mut Demux8080Conn) -> &mut H1ConnState {
    match conn {
        Demux8080Conn::H1(state) => state,
        _ => unreachable!(),
    }
}

fn proj_ws(conn: &mut Demux8080Conn) -> &mut WsConnState {
    match conn {
        Demux8080Conn::Ws(state) => state,
        _ => unreachable!(),
    }
}

fn proj_grpc(conn: &mut Demux8080Conn) -> &mut GrpcConnState {
    match conn {
        Demux8080Conn::Grpc(state) => state,
        _ => unreachable!(),
    }
}

fn h1_outcome(overrun: bool) -> Outcome {
    if overrun {
        Outcome::Overrun
    } else {
        Outcome::Ok
    }
}

pub struct Demux8080App<H1, WH: WsHandler, GH: GrpcHandler> {
    h1: H1,
    ws: WsApp<WH>,
    grpc: GrpcApp<GH, Identity>,
}

impl<H1, WH: WsHandler, GH: GrpcHandler> Demux8080App<H1, WH, GH> {
    pub fn new(h1: H1, ws: WsApp<WH>, grpc: GrpcApp<GH, Identity>) -> Self {
        Self { h1, ws, grpc }
    }

    pub fn h1(&self) -> &H1 {
        &self.h1
    }
}

impl<'d, H1, WH, GH> Application for Demux8080App<H1, WH, GH>
where
    H1: Application<Conn = H1ConnState, Wire = Identity>
        + DateHost
        + TimerHost<'d>
        + H1Project<Identity>,
    WH: WsHandler,
    GH: GrpcHandler,
{
    type Conn = Demux8080Conn;
    type Wire = Identity;

    fn on_chunk(
        &mut self,
        slot: &mut Slot<Self::Wire, State<Self::Conn>>,
        chunk: RecvChunk<'_>,
        aux: &mut Aux,
        driver: &mut Driver,
    ) -> Outcome {
        match lane_of(&slot.state.conn) {
            Lane::H1 => {
                return h1_outcome(self.h1.on_chunk_proj(
                    slot,
                    chunk.as_slice(),
                    aux,
                    driver,
                    proj_h1,
                ));
            }
            Lane::Ws => return self.ws.on_chunk_proj(slot, proj_ws, chunk, aux, driver),
            Lane::Grpc => return self.grpc.on_chunk_proj(slot, proj_grpc, chunk, aux, driver),
            Lane::Undecided => {}
        }

        let decision = {
            let Demux8080Conn::Undecided(buf) = &mut slot.state.conn else {
                unreachable!()
            };
            buf.extend_from_slice(chunk.as_slice());
            sniff(buf)
        };
        let Some(lane) = decision else {
            return Outcome::Ok;
        };
        let buffered = take_buffer(&mut slot.state.conn);
        match lane {
            Lane::H1 => {
                let mut state = H1ConnState::default();
                let overrun = matches!(state.recv.extend_accum(&buffered), ExtendOutcome::Overrun);
                slot.state.conn = Demux8080Conn::H1(state);
                if overrun {
                    return Outcome::Overrun;
                }
                h1_outcome(self.h1.on_chunk_proj(slot, &[], aux, driver, proj_h1))
            }
            Lane::Ws => {
                slot.state.conn = Demux8080Conn::Ws(WsConnState::default());
                self.ws
                    .on_chunk_proj(slot, proj_ws, RecvChunk::Borrowed(&buffered), aux, driver)
            }
            Lane::Grpc => {
                slot.state.conn = Demux8080Conn::Grpc(GrpcConnState::default());
                self.grpc.on_chunk_proj(
                    slot,
                    proj_grpc,
                    RecvChunk::Borrowed(&buffered),
                    aux,
                    driver,
                )
            }
            Lane::Undecided => unreachable!(),
        }
    }

    fn on_send(
        &mut self,
        slot: &mut Slot<Self::Wire, State<Self::Conn>>,
        sent: usize,
        aux: &mut Aux,
        driver: &mut Driver,
    ) {
        match lane_of(&slot.state.conn) {
            Lane::H1 => self.h1.on_send_proj(slot, proj_h1, sent, aux, driver),
            Lane::Ws => self.ws.on_send_proj(slot, sent, proj_ws, aux, driver),
            Lane::Grpc => self.grpc.on_send_proj(slot, sent, proj_grpc, aux, driver),
            Lane::Undecided => {}
        }
    }

    fn on_wake(
        &mut self,
        slot: &mut Slot<Self::Wire, State<Self::Conn>>,
        aux: &mut Aux,
        driver: &mut Driver,
    ) {
        match lane_of(&slot.state.conn) {
            Lane::H1 => self.h1.on_wake_proj(slot, proj_h1, aux, driver),
            Lane::Grpc => self.grpc.on_wake_proj(slot, proj_grpc, aux, driver),
            Lane::Ws | Lane::Undecided => {}
        }
    }

    fn on_close(&mut self, slot: &mut Slot<Self::Wire, State<Self::Conn>>, aux: &mut Aux) {
        if lane_of(&slot.state.conn) == Lane::H1 {
            self.h1.on_close_proj(slot, proj_h1, aux);
        }
    }
}

impl<H1: DateHost, WH: WsHandler, GH: GrpcHandler> DateHost for Demux8080App<H1, WH, GH> {
    fn date_stamp(&self) -> &Stamp {
        self.h1.date_stamp()
    }
}

impl<'d, H1: TimerHost<'d>, WH: WsHandler, GH: GrpcHandler> TimerHost<'d>
    for Demux8080App<H1, WH, GH>
{
    fn timer_cell(&self) -> &Cell<Option<Timer<'d>>> {
        self.h1.timer_cell()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_conn_is_empty_undecided() {
        assert!(
            matches!(Demux8080Conn::default(), Demux8080Conn::Undecided(buf) if buf.is_empty())
        );
    }

    #[test]
    fn take_buffer_extracts_bytes_and_resets() {
        let mut conn = Demux8080Conn::Undecided(b"replay".to_vec());
        let bytes = take_buffer(&mut conn);
        assert_eq!(bytes, b"replay");
        assert!(matches!(conn, Demux8080Conn::Undecided(buf) if buf.is_empty()));
    }

    #[test]
    fn lane_of_matches_variant() {
        assert_eq!(lane_of(&Demux8080Conn::default()), Lane::Undecided);
        assert_eq!(
            lane_of(&Demux8080Conn::H1(H1ConnState::default())),
            Lane::H1
        );
        assert_eq!(
            lane_of(&Demux8080Conn::Ws(WsConnState::default())),
            Lane::Ws
        );
        assert_eq!(
            lane_of(&Demux8080Conn::Grpc(GrpcConnState::default())),
            Lane::Grpc
        );
    }
}
