use o3::buffer;
use sark_grpc::{
    Code, Status, encode,
    protocol::request,
    server::service::{
        self,
        handler::{self, modes, output},
        reply::{Reply, Write},
        timers,
    },
};

#[derive(Clone, Copy, Debug, PartialEq, prost::Message)]
#[prost(skip_debug)]
pub struct SumRequest {
    #[prost(int32, tag = "1")]
    pub a: i32,
    #[prost(int32, tag = "2")]
    pub b: i32,
}

#[derive(Clone, Copy, Debug, PartialEq, prost::Message)]
#[prost(skip_debug)]
pub struct StreamRequest {
    #[prost(int32, tag = "1")]
    pub a: i32,
    #[prost(int32, tag = "2")]
    pub b: i32,
    #[prost(int32, tag = "3")]
    pub count: i32,
}

#[derive(Clone, Copy, Debug, PartialEq, prost::Message)]
#[prost(skip_debug)]
pub struct SumReply {
    #[prost(int32, tag = "1")]
    pub result: i32,
}

impl encode::Message for SumReply {
    type Plan<'a> = &'a Self;

    fn plan(&self) -> Self::Plan<'_> {
        self
    }
}

impl encode::Plan for &SumReply {
    fn write<S: encode::Sink>(self, sink: S) -> Result<S::Output, sark_grpc::Status> {
        let mut bytes = [0; 11];
        let mut remaining = bytes.as_mut_slice();
        let Ok(()) = prost::Message::encode(self, &mut remaining) else {
            unreachable!("encode")
        };
        let written = 11 - remaining.len();
        sink.try_slices([&bytes[..written]])
    }
}

pub struct BenchSvc;

pub struct Replies {
    result: i32,
    remaining: u32,
}

impl Iterator for Replies {
    type Item = SumReply;

    fn next(&mut self) -> Option<Self::Item> {
        self.remaining = self.remaining.checked_sub(1)?;
        let result = self.result;
        self.result = self.result.wrapping_add(1);
        Some(SumReply { result })
    }
}

#[derive(Default)]
pub enum Call {
    #[default]
    Unknown,
    GetSum,
    StreamSum(<output::Streaming<BenchSvc> as handler::Handler>::Call),
}

impl handler::Handler for BenchSvc {
    type Call = Call;
    type Timer = timers::Off;

    fn start<W: Write>(
        &mut self,
        _: &mut (),
        _: &mut service::Stream,
        head: &request::Head,
        reply: &mut Reply<'_, W>,
    ) -> handler::Start<Self::Call> {
        handler::Start::buffered(match head.path() {
            b"/benchmark.BenchmarkService/GetSum" => Call::GetSum,
            b"/benchmark.BenchmarkService/StreamSum" => Call::StreamSum(Default::default()),
            _ => {
                reply.finish_with(Status::from_code(Code::Unimplemented));
                Call::Unknown
            }
        })
    }

    fn request<S: buffer::raw::Segment, W: Write>(
        &mut self,
        context: &mut (),
        call: &mut Self::Call,
        request: service::Request<'_, S>,
        response: &mut service::Response<'_, W>,
    ) -> handler::RequestState {
        match call {
            Call::GetSum => modes::Unary::new(BenchSvc, encode::Prost::new()).request(
                context,
                &mut (),
                request,
                response,
            ),
            Call::StreamSum(call) => output::Streaming::new(BenchSvc, encode::Prost::new())
                .request(context, call, request, response),
            Call::Unknown => {
                response.finish_with(Status::from_code(Code::Unimplemented));
                handler::RequestState::Complete
            }
        }
    }

    fn output<W: Write>(
        &mut self,
        context: &mut (),
        call: &mut Self::Call,
        output: &mut timers::Output<'_, '_, '_, Self::Timer>,
        reply: &mut Reply<'_, W>,
    ) -> handler::OutputState {
        let code = match call {
            Call::StreamSum(call) => {
                return output::Streaming::new(BenchSvc, encode::Prost::new())
                    .output(context, call, output, reply);
            }
            Call::GetSum => Code::Internal,
            Call::Unknown => Code::Unimplemented,
        };
        reply.finish_with(Status::from_code(code));
        handler::OutputState::Complete
    }
}

impl modes::UnaryFn for BenchSvc {
    type Response = SumReply;
    type Codec = encode::Prost<SumReply, SumRequest>;

    fn unary<'a, S: buffer::raw::Segment + 'a>(
        &mut self,
        _: &mut (),
        request: modes::Request<SumRequest>,
    ) -> modes::Response<SumReply> {
        modes::Response::new(SumReply {
            result: request.body.a.wrapping_add(request.body.b),
        })
    }
}

impl output::StreamFn for BenchSvc {
    type Response = SumReply;
    type Stream = Replies;
    type Codec = encode::Prost<SumReply, StreamRequest>;

    fn stream<'a, S: buffer::raw::Segment + 'a>(
        &mut self,
        _: &mut (),
        request: modes::Request<StreamRequest>,
    ) -> output::Response<Self::Stream> {
        let body = request.body;
        output::Response::new(Replies {
            result: body.a.wrapping_add(body.b),
            remaining: body.count.max(0) as u32,
        })
    }
}
