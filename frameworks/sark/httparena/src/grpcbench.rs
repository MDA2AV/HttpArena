use std::cell::RefCell;

use sark_grpc::server::{Config, dispatch_buffered};
use sark_grpc::status::Status;
use sark_grpc::{
    Metadata, RequestHead, Routes, StreamingRequest, StreamingResponse, UnaryRequest, UnaryResponse,
};

include!(concat!(env!("OUT_DIR"), "/benchmark.rs"));

pub struct BenchSvc;

impl BenchmarkServiceService for BenchSvc {
    fn get_sum(&mut self, request: UnaryRequest<SumRequest>) -> UnaryResponse<SumReply> {
        UnaryResponse::new(SumReply {
            result: request.message.a.wrapping_add(request.message.b),
        })
    }

    fn stream_sum(
        &mut self,
        request: StreamingRequest<StreamRequest>,
    ) -> StreamingResponse<SumReply> {
        let mut replies = Vec::new();
        for msg in &request.messages {
            let sum = msg.a.wrapping_add(msg.b);
            let count = msg.count.max(0) as usize;
            for _ in 0..count {
                replies.push(SumReply { result: sum });
            }
        }
        StreamingResponse::new(replies)
    }
}

fn head(path: &[u8]) -> RequestHead {
    RequestHead {
        path: path.to_vec(),
        authority: None,
        metadata: Metadata::new(),
    }
}

type BenchRoutes = Routes<__SarkGrpcBenchmarkServiceRoutes<BenchSvc>>;

pub fn dispatch(path: &[u8], body: &[u8]) -> (Vec<u8>, Status) {
    thread_local! {
        static ROUTES: RefCell<BenchRoutes> = RefCell::new(benchmark_service_routes(BenchSvc));
    }
    let response = ROUTES
        .with_borrow_mut(|routes| dispatch_buffered(routes, head(path), body, &Config::default()));
    let mut out = Vec::new();
    match response.encode_body(&mut out) {
        Ok(()) => (out, response.status),
        Err(status) => (Vec::new(), status),
    }
}

#[cfg(test)]
mod tests {
    use prost::Message;
    use sark_grpc::frame::{Deframer, MessageFrame};
    use sark_grpc::status::Code;

    use super::*;

    const GET_SUM: &[u8] = b"/benchmark.BenchmarkService/GetSum";
    const STREAM_SUM: &[u8] = b"/benchmark.BenchmarkService/StreamSum";

    fn frame(payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        MessageFrame::encode(false, payload, &mut out).unwrap();
        out
    }

    fn deframe(bytes: &[u8]) -> Vec<MessageFrame> {
        let mut deframer = Deframer::new(4 * 1024 * 1024);
        let mut out = Vec::new();
        deframer.push(bytes, &mut out).unwrap();
        out
    }

    #[test]
    fn get_sum_decodes_request_and_frames_reply() {
        let mut payload = Vec::new();
        SumRequest { a: 7, b: 35 }.encode(&mut payload).unwrap();
        let (frames, status) = dispatch(GET_SUM, &frame(&payload));
        assert_eq!(status.code(), Code::Ok);
        let messages = deframe(&frames);
        assert_eq!(messages.len(), 1);
        let reply = SumReply::decode(messages[0].payload.as_slice()).unwrap();
        assert_eq!(reply.result, 42);
    }

    #[test]
    fn stream_sum_emits_count_replies() {
        let mut payload = Vec::new();
        StreamRequest {
            a: 4,
            b: 6,
            count: 3,
        }
        .encode(&mut payload)
        .unwrap();
        let (frames, status) = dispatch(STREAM_SUM, &frame(&payload));
        assert_eq!(status.code(), Code::Ok);
        let messages = deframe(&frames);
        assert_eq!(messages.len(), 3);
        for message in &messages {
            let reply = SumReply::decode(message.payload.as_slice()).unwrap();
            assert_eq!(reply.result, 10);
        }
    }

    #[test]
    fn unknown_method_is_unimplemented() {
        let (frames, status) = dispatch(b"/benchmark.BenchmarkService/Missing", &[]);
        assert!(frames.is_empty());
        assert_eq!(status.code(), Code::Unimplemented);
    }

    #[test]
    fn get_sum_without_message_is_invalid_argument() {
        let (frames, status) = dispatch(GET_SUM, &[]);
        assert!(frames.is_empty());
        assert_eq!(status.code(), Code::InvalidArgument);
    }
}
