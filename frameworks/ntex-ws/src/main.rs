use std::io;

use ntex::http::{HttpService, Request, Response, ResponseError, body::BodySize, h1};
use ntex::io::{Filter, Io};
use ntex::server::LoadBalancing;
use ntex::util::ByteString;
use ntex::ws;

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

/// Plain requests never upgrade: `/ws` answers with the handshake error, so a
/// GET without upgrade headers is rejected instead of getting 200.
async fn request(req: Request) -> Result<Response, io::Error> {
    Ok(if req.path() == "/ws" {
        ws::verify_handshake(req.head()).map_or_else(
            |err| err.error_response(),
            |()| Response::BadRequest().build(),
        )
    } else {
        Response::NotFound().build()
    })
}

/// Takes over upgraded `/ws` connections from the h1 dispatcher.
async fn control<F: Filter>(
    msg: h1::Control<F, io::Error>,
) -> Result<h1::ControlAck<F>, io::Error> {
    let upg = match msg {
        h1::Control::Upgrade(upg) => upg,
        msg => return Ok(msg.ack()),
    };
    if upg.get_ref().path() != "/ws" {
        return Ok(upg.fail_with(Response::NotFound().build()));
    }
    let res = match ws::handshake(upg.get_ref().head()) {
        Ok(mut res) => res.message_body(()),
        Err(err) => return Ok(upg.fail(err)),
    };

    let (ack, io, _, codec) = upg.handle();
    // The h1 dispatcher may have armed a headers-read timer; without a
    // dispatcher here it would only surface as a spurious recv timeout.
    io.stop_timer();
    if io
        .encode(h1::Message::Item((res, BodySize::Empty)), &codec)
        .is_ok()
    {
        echo(&io).await;
    }
    Ok(ack)
}

/// Echoes frames until the peer closes. `recv` waits out write back-pressure
/// itself, so encoding without awaiting the flush cannot grow the buffer
/// without bound.
async fn echo<F: Filter>(io: &Io<F>) {
    let codec = ws::Codec::new();
    while let Ok(Some(frame)) = io.recv(&codec).await {
        let msg = match frame {
            // The codec has already validated the payload as UTF-8.
            ws::Frame::Text(text) => match ByteString::try_from(text) {
                Ok(text) => ws::Message::Text(text),
                Err(_) => break,
            },
            ws::Frame::Binary(bin) => ws::Message::Binary(bin),
            ws::Frame::Ping(msg) => ws::Message::Pong(msg),
            ws::Frame::Close(reason) => {
                let _ = io.encode(ws::Message::Close(reason), &codec);
                break;
            }
            ws::Frame::Pong(_) | ws::Frame::Continuation(_) => continue,
        };
        if io.encode(msg, &codec).is_err() {
            break;
        }
    }
    let _ = io.shutdown().await;
}

#[ntex::main]
async fn main() -> io::Result<()> {
    ntex::server::build()
        .backlog(1024)
        // each worker accepts on its own `SO_REUSEPORT` listener
        .load_balancing(LoadBalancing::Reuseport)
        .bind(
            "ws",
            "0.0.0.0:8080",
            ntex::SharedCfg::default(),
            async |_| HttpService::h1(request).control(control),
        )?
        .run()
        .await
}
