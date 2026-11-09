use std::pin::pin;

use dope::core::driver::settings;
use dope_fiber::{BlockOn, abi};
use dope_test::fibers;
use httparena_sark::files::{Body, CHUNK_BYTES, Error, Root};

pub const ORIGINAL: &[u8] = &[b'a'; CHUNK_BYTES + 3];
pub const REPLACEMENT: &[u8] = b"new";
pub const TRUNCATED: &[u8] = b"n";
pub const EMPTY: &[u8] = b"";

pub struct Profile;

impl settings::Profile for Profile {
    const QUEUES: settings::QueueLayout = settings::QueueLayout::fixed::<64, 128>();
    const SCHEDULER: settings::Schedule = settings::Schedule::fixed::<16, 1>();
    const RECEIVE: settings::Receive = settings::Receive::fixed::<2, 4096>();
    const RESIDENT_DOMAINS: settings::Domain = settings::Domain::ONE;
}

pub fn collect<'d, A: BlockOn<'d>>(app: &mut A, body: Body<'_, 'd>) -> Result<Vec<u8>, Error> {
    let mut body = pin!(abi::Task::new(body));
    let mut bytes = Vec::new();
    while let Some(chunk) = fibers::TEST
        .try_run(
            app,
            abi::PollFn::admitted(|admit| admit.poll_next(body.as_mut()).0),
        )
        .expect("body progress")
    {
        bytes.extend_from_slice(chunk?.owner().as_ref());
    }
    Ok(bytes)
}

pub fn open<'p, 'd>(
    app: &mut impl BlockOn<'d>,
    root: &Root<'p, 'd>,
    name: &[u8],
) -> Result<Body<'p, 'd>, Error> {
    fibers::TEST
        .try_run(app, root.open(name)?)
        .expect("file progress")
}
