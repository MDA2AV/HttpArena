use std::{mem::MaybeUninit, num::NonZero, process::ExitCode};

use dope::{
    core::{Backend, dope_sys::io::fd::Fd, driver::settings, platform::affinity::Cpu},
    manifold::timing::Throughput,
    runtime::process,
};
use dope_quic::runtime::routing;
use httparena_sark::{
    boot::Boot,
    fail,
    runtime::{self, Worker},
};
use o3::mem::slot;

fn share(total: NonZero<usize>, workers: NonZero<usize>, index: usize) -> NonZero<usize> {
    let value = total.get() / workers.get() + usize::from(index < total.get() % workers.get());
    let Some(value) = NonZero::new(value) else {
        unreachable!("workers")
    };
    value
}

fn start() -> Result<(), ExitCode> {
    let boot = Boot::from_env().map_err(|cause| fail(format_args!("configuration: {cause:?}")))?;
    let max_connections = boot
        .max_connections
        .unwrap_or(NonZero::<usize>::MIN.saturating_add(65_535));
    let cpus = Cpu::current().map_err(|cause| fail(format_args!("CPU discovery: {cause:?}")))?;
    let count = boot.cpu_count.map_or(cpus.len(), NonZero::get);
    if count > cpus.len()
        || count > max_connections.get()
        || (boot.database_url.is_some() && count > boot.database_connections.get())
    {
        return Err(fail(format_args!(
            "worker count {count} exceeds CPU or connection capacity"
        )));
    }
    let layout = process::Layout::pinned(cpus.take(count))
        .map_err(|cause| fail(format_args!("CPU layout: {cause:?}")))?;
    let count = layout.count();
    let (soft, _) =
        Backend::try_limit().map_err(|cause| fail(format_args!("descriptor limit: {cause:?}")))?;
    let files = <Throughput as settings::Profile>::FILES;
    let available = soft
        .checked_sub(files.outbound().count().get() as u64)
        .ok_or_else(|| {
            fail(format_args!(
                "descriptor limit {soft} is below the runtime requirement"
            ))
        })?;
    let listeners = if boot.h1_only { 1 } else { boot.tcp_bind.len() };
    let tcp_capacity =
        NonZero::new((available / listeners as u64).min(max_connections.get() as u64) as usize)
            .ok_or_else(|| {
                fail(format_args!(
                    "descriptor limit {soft} cannot admit {listeners} TCP listeners"
                ))
            })?;
    let requested = max_connections.get().div_ceil(count.get());
    if boot.max_connections.is_some() && requested > tcp_capacity.get() {
        return Err(fail(format_args!(
            "TCP connection capacity {requested} per worker exceeds {tcp_capacity} under descriptor limit {soft}"
        )));
    }
    let mut h3 = if boot.h1_only {
        None
    } else {
        let count = u16::try_from(count.get())
            .map_err(|cause| fail(format_args!("QUIC worker count: {cause:?}")))?;
        let count = routing::Count::try_from(count)
            .map_err(|cause| fail(format_args!("QUIC worker count: {cause:?}")))?;
        Some(
            routing::Group::bind(boot.h3_bind, count)
                .map_err(|cause| fail(format_args!("QUIC routing: {cause:?}")))?,
        )
    };
    let mut bindings = h3.as_mut().map(routing::Group::split);
    let inputs = std::iter::repeat_n(boot, count.get())
        .enumerate()
        .map(|(index, boot)| (index, boot, bindings.as_mut().and_then(Iterator::next)));
    let mut signal = MaybeUninit::uninit();
    layout
        .try_map(inputs, |(index, boot, h3)| {
            let connections = share(max_connections, count, index);
            Worker {
                connections,
                tcp_connections: connections.min(tcp_capacity),
                database_connections: if boot.database_url.is_some() {
                    share(boot.database_connections, count, index)
                } else {
                    NonZero::<usize>::MIN
                },
                boot,
                h3,
            }
        })
        .map_err(|cause| fail(format_args!("worker inputs: {cause:?}")))?
        .run(slot::Vacant::new(&mut signal), |input, context| {
            runtime::serve(input, context, runtime::Bindings::default())
        })
        .map_err(|cause| {
            cause.fold(ExitCode::FAILURE, |status, cause| {
                let output = fail(format_args!("process: {cause:?}"));
                if status == ExitCode::from(2)
                    || matches!(cause, process::failure::execute::Fault::Worker(
                        process::failure::execute::Worker::Entry { source, .. }
                    ) if source == ExitCode::from(2))
                {
                    ExitCode::from(2)
                } else {
                    output
                }
            })
        })
}

fn main() -> ExitCode {
    match start() {
        Ok(()) => ExitCode::SUCCESS,
        Err(status) => status,
    }
}
