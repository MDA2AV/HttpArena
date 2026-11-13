use std::{cell::Cell, io, ops::ControlFlow};

use sark_ws::{
    frame,
    server::{Error, Message, Response, Session, app::Sink},
};

const MAX_MESSAGE: usize = 16 * 1024 * 1024;

#[sark::request]
pub struct Upgrade {}

#[sark::duplex(pub)]
pub fn open<'state, P, R>(
    _: Upgrade,
    state: &'state crate::State<'_, '_, P, R>,
) -> Session<Echo<'state>> {
    Session::new(
        Echo {
            diagnostics: state.diagnostics,
        },
        MAX_MESSAGE,
        MAX_MESSAGE,
    )
}

pub struct Echo<'a> {
    pub diagnostics: &'a Cell<Option<io::Error>>,
}

impl Sink for Echo<'_> {
    fn capacity(&self, payload: usize) -> Result<usize, Error> {
        Ok(frame::Plan::new(0x2, true, payload, false)?.wire_len())
    }

    fn message(
        &self,
        message: Message<'_>,
        response: &mut Response<'_>,
    ) -> Result<ControlFlow<()>, Error> {
        match message {
            Message::Text(text) => response.try_text(text)?,
            Message::Binary(bytes) => response.try_binary(bytes)?,
        }
        Ok(ControlFlow::Continue(()))
    }

    fn failed(&self, error: Error) {
        crate::diagnostic(self.diagnostics, format_args!("WebSocket: {error:?}"));
    }
}
