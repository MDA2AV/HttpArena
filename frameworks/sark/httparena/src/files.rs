use std::{cell::Cell, ffi::OsStr, io, mem, os::unix::ffi::OsStrExt as _, path::Path, task::Poll};

use dope::{
    core::{
        Errno,
        io::{fs, transfer},
    },
    manifold::file::read,
};
use dope_fiber::{abi, context, file::Operation};
use o3::{
    buffer::{resident, storage},
    mem::Lease,
};
use sark::http::{
    field::{self, Value, head::AcceptEncoding},
    payload::response::{
        dispatch::{Stream, chunk::Chunk},
        headers::{set::Set, value::Item},
        status::Code,
    },
};

pub const CHUNK_BYTES: usize = 16 * 1024;
const BR: Value<&'static [u8]> = field::literal!(Value::try_bytes(b"br"));
const GZIP: Value<&'static [u8]> = field::literal!(Value::try_bytes(b"gzip"));

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Coding {
    Identity,
    Gzip,
    Br,
}

pub struct Root<'p, 'd> {
    directory: fs::Dir,
    port: &'p read::Port<'d>,
    budget: resident::Budget<'d>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Path(fs::path::Error),
    NotAcceptable,
    Confine(fs::path::ConfineError),
    Admission(read::Admission),
    Open(read::Error),
    Metadata(read::MetadataError),
    Kind(fs::Kind),
    Buffer(resident::AllocError),
    Read(read::Error),
    Offset(fs::Extent),
    Changed {
        expected: fs::Offset,
        observed: fs::Offset,
    },
    Truncated {
        expected: fs::Offset,
        observed: fs::Offset,
    },
    Copy(resident::copy::Error),
}

enum Stage<'p, 'd> {
    Read(read::Read<read::Release<'d>>),
    Wait(read::Ticket<'p, 'd>),
    Done,
}

pub struct Body<'p, 'd> {
    port: &'p read::Port<'d>,
    budget: resident::Budget<'d>,
    end: fs::Offset,
    stage: Stage<'p, 'd>,
}

pub type Response<'p, 'd> = Stream<'static, Body<'p, 'd>, 3>;

#[sark::request]
pub struct Request {
    #[path]
    file: storage::Shared,
    #[header("accept-encoding")]
    encoding: Option<AcceptEncoding>,
}

#[sark::handler(pub)]
pub async fn static_endpoint<'files, P, R>(
    request: Request,
    state: &crate::State<'files, '_, P, R>,
) -> Response<'files, '_> {
    let content_type = content_type(request.file.as_ref());
    let component = match fs::path::Component::parse_os(OsStr::from_bytes(request.file.as_ref())) {
        Ok(component) => component,
        Err(cause) => return state.files.reject(Error::Path(cause), state.diagnostics),
    };
    let encoding = request.encoding.unwrap_or_default();
    let mut choices = [
        (encoding.br(), Coding::Br),
        (encoding.gzip(), Coding::Gzip),
        (encoding.identity(), Coding::Identity),
    ];
    choices.sort_unstable_by(|left, right| right.cmp(left));
    for (quality, coding) in choices {
        if quality == 0 {
            break;
        }
        let opening = match coding {
            Coding::Identity => state.files.open_component(component),
            Coding::Br | Coding::Gzip => {
                let suffix = if coding == Coding::Br { b".br" } else { b".gz" };
                let mut name = [0; u8::MAX as usize + 3];
                let end = request.file.len();
                name[..end].copy_from_slice(request.file.as_ref());
                name[end..end + suffix.len()].copy_from_slice(suffix);
                match fs::path::Component::parse_os(OsStr::from_bytes(&name[..end + suffix.len()]))
                {
                    Ok(component) => state.files.open_component(component),
                    Err(fs::path::Error::Component { .. }) => continue,
                    Err(cause) => Err(Error::Path(cause)),
                }
            }
        };
        let result = match opening {
            Ok(opening) => opening.await,
            Err(cause) => Err(cause),
        };
        let encoding = match coding {
            Coding::Identity => None,
            Coding::Gzip => Some(GZIP),
            Coding::Br => Some(BR),
        };
        match result {
            Ok(body) => return body.response(content_type, encoding),
            Err(Error::Open(read::Error::System(Errno::NOT_FOUND))) if encoding.is_some() => {}
            Err(cause) => return state.files.reject(cause, state.diagnostics),
        }
    }
    state.files.reject(Error::NotAcceptable, state.diagnostics)
}

impl<'p, 'd> Root<'p, 'd> {
    pub fn try_new(
        path: &Path,
        port: &'p read::Port<'d>,
        budget: resident::Budget<'d>,
    ) -> Result<Self, fs::open::Error> {
        Ok(Self {
            directory: fs::Dir::open(path)?,
            port,
            budget,
        })
    }

    pub fn open(
        &self,
        name: &[u8],
    ) -> Result<impl abi::Fiber<'d, Output = Result<Body<'p, 'd>, Error>> + use<'p, 'd>, Error>
    {
        let component =
            fs::path::Component::parse_os(OsStr::from_bytes(name)).map_err(Error::Path)?;
        self.open_component(component)
    }

    fn open_component(
        &self,
        component: fs::path::Component<'_>,
    ) -> Result<impl abi::Fiber<'d, Output = Result<Body<'p, 'd>, Error>> + use<'p, 'd>, Error>
    {
        let path = self
            .directory
            .confine_name(component)
            .map_err(Error::Confine)?;
        let request = fs::OpenRequest::new(
            path,
            fs::open::Options::new(fs::open::Access::Read).nonblock(),
        );
        let port = self.port;
        let budget = self.budget;
        Ok(dope_fiber::fiber! { 'd => async move {
            let file = match Operation::new(port, read::Request::Open(request))
                .await
                .map_err(|error| Error::Admission(error.into_parts().1))?
            {
                read::Completion::Open { result, .. } => result.map_err(Error::Open)?,
                _ => unreachable!("open"),
            };
            let (file, (kind, length, _)) =
                match Operation::new(port, read::Request::Metadata(read::Metadata::new(file)))
                    .await
                    .map_err(|error| Error::Admission(error.into_parts().1))?
                {
                    read::Completion::Metadata { file, result } => {
                        (file, result.map_err(Error::Metadata)?)
                    }
                    _ => unreachable!("metadata"),
                };
            if !kind.is_regular() {
                return Err(Error::Kind(kind));
            }
            Body::try_new(port, budget, file, fs::Offset::from(length))
        } })
    }

    fn reject(&self, cause: Error, diagnostics: &Cell<Option<io::Error>>) -> Response<'p, 'd> {
        let status = cause.status();
        if status.as_u16() >= 500 {
            crate::diagnostic(diagnostics, format_args!("static file: {cause:?}"));
        }
        Body {
            port: self.port,
            budget: self.budget,
            end: fs::Offset::fixed::<0>(),
            stage: Stage::Done,
        }
        .response(field::literal!(Value::try_bytes(b"text/plain")), None)
        .with_status(status)
    }
}

impl Error {
    pub fn status(self) -> Code {
        match self {
            Self::Path(_) | Self::Kind(_) => Code::NOT_FOUND,
            Self::NotAcceptable => Code::NOT_ACCEPTABLE,
            Self::Open(read::Error::System(
                Errno::NOT_FOUND | Errno::NOT_DIRECTORY | Errno::SYMLINK_LOOP,
            )) => Code::NOT_FOUND,
            Self::Admission(read::Admission::Full) | Self::Buffer(_) | Self::Copy(_) => {
                Code::SERVICE_UNAVAILABLE
            }
            _ => Code::INTERNAL_SERVER_ERROR,
        }
    }
}

impl<'p, 'd> Body<'p, 'd> {
    fn try_new(
        port: &'p read::Port<'d>,
        budget: resident::Budget<'d>,
        file: fs::File,
        end: fs::Offset,
    ) -> Result<Self, Error> {
        let stage = if end == fs::Offset::fixed::<0>() {
            Stage::Done
        } else {
            Stage::Read(Self::try_read(&budget, file, fs::Offset::fixed::<0>())?)
        };
        Ok(Self {
            port,
            budget,
            end,
            stage,
        })
    }

    fn try_read(
        budget: &resident::Budget<'d>,
        file: fs::File,
        offset: fs::Offset,
    ) -> Result<read::Read<read::Release<'d>>, Error> {
        let output = storage::Owned::try_allocate(budget, CHUNK_BYTES).map_err(Error::Buffer)?;
        match read::Read::try_new(file, Lease::open(read::Release::default(), output), offset) {
            Ok(request) => Ok(request),
            Err(_) => unreachable!("buffer"),
        }
    }

    fn response(
        self,
        content_type: Value<&'static [u8]>,
        encoding: Option<Value<&'static [u8]>>,
    ) -> Response<'p, 'd> {
        Stream::new(self).headers(Set::from_optional([
            Some(Item::borrow(
                sark::header_name!("content-type"),
                content_type,
            )),
            Some(Item::borrow(
                sark::header_name!("vary"),
                field::literal!(Value::try_bytes(b"Accept-Encoding")),
            )),
            encoding.map(|value| Item::borrow(sark::header_name!("content-encoding"), value)),
        ]))
    }

    fn complete(
        &mut self,
        completed: read::Completion<read::Release<'d>>,
    ) -> Result<Chunk<'d>, Error> {
        let read::Completion::Read { request, result } = completed else {
            unreachable!("read")
        };
        let amount = result.map_err(Error::Read)?;
        let offset = request.offset();
        if amount.is_zero() {
            return Err(Error::Truncated {
                expected: self.end,
                observed: offset,
            });
        }
        let next = offset.checked_add(amount).map_err(Error::Offset)?;
        if next > self.end {
            return Err(Error::Changed {
                expected: self.end,
                observed: next,
            });
        }
        let owner = if next == self.end {
            request.into_parts().1.into_parts().1.freeze()
        } else if amount == transfer::Len::fixed::<CHUNK_BYTES>() {
            let (file, output, _) = request.into_parts();
            self.stage = Stage::Read(Self::try_read(&self.budget, file, next)?);
            output.into_parts().1.freeze()
        } else {
            let owner =
                resident::Shared::try_copy(&request.output(), &self.budget).map_err(Error::Copy)?;
            self.stage = Stage::Read(request.at(next));
            owner
        };
        match Chunk::try_new(owner) {
            Ok(chunk) => Ok(chunk),
            Err(_) => unreachable!("empty"),
        }
    }
}

impl<'d> abi::Stream<'d> for Body<'_, 'd> {
    type Item = Result<Chunk<'d>, Error>;

    fn poll_next(call: context::PollCall<'_, '_, 'd, Self>) -> Poll<Option<Self::Item>> {
        let (this, cx) = call.into_parts();
        let this = this.get_mut();
        let ticket = match mem::replace(&mut this.stage, Stage::Done) {
            Stage::Read(request) => match this.port.try_request(read::Request::Read(request)) {
                Ok(ticket) => ticket,
                Err(error) => {
                    return Poll::Ready(Some(Err(Error::Admission(error.into_parts().1))));
                }
            },
            Stage::Wait(ticket) => ticket,
            Stage::Done => return Poll::Ready(None),
        };
        match ticket.poll(Some(cx.as_ref().completion())) {
            read::Poll::Pending(ticket) => {
                this.stage = Stage::Wait(ticket);
                Poll::Pending
            }
            read::Poll::Ready(completed) => Poll::Ready(Some(this.complete(completed))),
        }
    }
}

pub fn content_type(name: &[u8]) -> Value<&'static [u8]> {
    let extension = name.rsplit(|byte| *byte == b'.').next().unwrap_or_default();
    match extension {
        b"html" | b"htm" => field::literal!(Value::try_bytes(b"text/html; charset=utf-8")),
        b"css" => field::literal!(Value::try_bytes(b"text/css; charset=utf-8")),
        b"js" | b"mjs" => {
            field::literal!(Value::try_bytes(b"application/javascript; charset=utf-8"))
        }
        b"json" => field::literal!(Value::try_bytes(b"application/json")),
        b"svg" => field::literal!(Value::try_bytes(b"image/svg+xml")),
        b"webp" => field::literal!(Value::try_bytes(b"image/webp")),
        b"woff2" => field::literal!(Value::try_bytes(b"font/woff2")),
        b"png" => field::literal!(Value::try_bytes(b"image/png")),
        b"jpg" | b"jpeg" => field::literal!(Value::try_bytes(b"image/jpeg")),
        b"ico" => field::literal!(Value::try_bytes(b"image/x-icon")),
        b"txt" => field::literal!(Value::try_bytes(b"text/plain; charset=utf-8")),
        _ => field::literal!(Value::try_bytes(b"application/octet-stream")),
    }
}
