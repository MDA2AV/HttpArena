use httparena_sark::grpcbench::{BenchSvc, StreamRequest, SumReply};
use o3::buffer::storage;
use sark_grpc::{
    encode::{Message as _, Plan as _},
    metadata::{Decoded, Metadata},
    protocol::request::Head,
    server::service::handler::{modes, output::StreamFn as _},
};
use sark_h2::stream::Id;

#[test]
fn streams_signed_replies_without_materializing_count() {
    for (b, count) in [(1, -1), (1, 0), (1, 3), (1, i32::MAX), (0, 3)] {
        let response = BenchSvc.stream::<storage::Shared>(
            &mut (),
            modes::Request {
                stream_id: Id::new(1).expect("stream"),
                head: Head::new(
                    b"/benchmark.BenchmarkService/StreamSum",
                    None,
                    &Metadata::new(),
                )
                .expect("request"),
                body: StreamRequest {
                    a: i32::MAX,
                    b,
                    count,
                },
                trailers: Decoded::new(),
            },
        );
        let mut messages = response.messages;
        if count <= 0 {
            assert_eq!(messages.next(), None);
            continue;
        }
        let reply = messages.next().expect("first reply");
        let mut encoded = storage::Shared::new();
        reply.plan().write(&mut encoded).expect("encode reply");
        let expected: &[u8] = if b == 0 {
            &[0x08, 0xff, 0xff, 0xff, 0xff, 0x07]
        } else {
            &[
                0x08, 0x80, 0x80, 0x80, 0x80, 0xf8, 0xff, 0xff, 0xff, 0xff, 0x01,
            ]
        };
        assert_eq!(encoded.as_slice(), expected);
        let following = if b == 0 {
            [i32::MIN, i32::MIN + 1]
        } else {
            [i32::MIN + 1, i32::MIN + 2]
        };
        for result in following {
            assert_eq!(messages.next(), Some(SumReply { result }));
        }
        if count == 3 {
            assert_eq!(messages.next(), None);
        }
    }
}
