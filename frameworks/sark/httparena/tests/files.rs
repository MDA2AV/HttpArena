pub mod common;

use std::{env, fs, num::NonZero, os::unix::fs::symlink};

use dope::{
    core::{
        Errno,
        driver::{
            life::{creation::Attempt, recovery},
            route::KeyTag,
            settings::claim::Needs,
            storage::Resident,
        },
        io::fs::Offset,
    },
    manifold::{app::Host, file::read},
    runtime::executor::{Executor, session},
};
use dope_test::harness::{scenario, support::file::Directory};
use httparena_sark::files::{CHUNK_BYTES, Error, Root};

use common::files::{EMPTY, ORIGINAL, Profile, REPLACEMENT, TRUNCATED, collect, open};

#[test]
fn serves_current_confined_files_and_rejects_short_reads() {
    let directory = Directory::try_with(&env::temp_dir(), "arena_files", |result| {
        result.expect("remove files")
    })
    .expect("fixture directory");
    let path = directory.path().join("site.css");
    fs::write(&path, ORIGINAL).expect("original file");
    fs::write(directory.path().join("empty"), EMPTY).expect("empty file");
    fs::create_dir(directory.path().join("nested")).expect("nested directory");
    symlink(&path, directory.path().join("link")).expect("symlink");
    let layout = read::Layout::<KeyTag<12>>::try_new(NonZero::<u32>::MIN).expect("read layout");
    let config = Needs::from_tree(&layout)
        .expect("file claims")
        .resolve::<Profile>()
        .expect("driver settings");
    let mut attempt = Attempt::new();
    let executor = Executor::new(&mut attempt, config)
        .map_err(|error| format!("{:?}", error.kind()))
        .expect("driver creation");
    executor.run(|executor| {
        executor
            .enter_with(
                |mut session| {
                    let port = layout.try_port().expect("file slots");
                    let reader = read::Reader::<KeyTag<12>>::try_new(&port, &mut session.driver())
                        .expect("file reader");
                    let budget = session
                        .driver()
                        .storage
                        .budget(Resident::bytes(CHUNK_BYTES * 2))
                        .expect("body budget");
                    let root = Root::try_new(directory.path(), &port, budget).expect("file root");
                    let mut finish = session::Completion::new();
                    session
                        .with_quiesce(
                            &mut finish,
                            Host::new(reader),
                            scenario::TIMEOUT,
                            |mut app| {
                                assert!(matches!(root.open(b"../site.css"), Err(Error::Path(_))));
                                for (name, expected) in [
                                    (b"missing".as_slice(), Errno::NOT_FOUND),
                                    (b"link".as_slice(), Errno::SYMLINK_LOOP),
                                ] {
                                    let result = open(&mut app, &root, name);
                                    assert!(matches!(
                                        result,
                                        Err(Error::Open(read::Error::System(cause)))
                                            if cause == expected
                                    ));
                                }
                                let result = open(&mut app, &root, b"nested");
                                assert!(matches!(result, Err(Error::Kind(_))));
                                let body =
                                    open(&mut app, &root, b"site.css").expect("regular file");
                                assert_eq!(collect(&mut app, body).expect("file bytes"), ORIGINAL);
                                assert_eq!(budget.resident(), 0);
                                fs::write(directory.path().join("replacement"), REPLACEMENT)
                                    .expect("replacement");
                                fs::rename(directory.path().join("replacement"), &path)
                                    .expect("replace file");
                                let body =
                                    open(&mut app, &root, b"site.css").expect("replacement file");
                                assert_eq!(
                                    collect(&mut app, body).expect("replacement bytes"),
                                    REPLACEMENT
                                );
                                let body = open(&mut app, &root, b"site.css")
                                    .expect("file before truncation");
                                fs::write(&path, TRUNCATED).expect("truncate file");
                                assert_eq!(
                                    collect(&mut app, body),
                                    Err(Error::Truncated {
                                        expected: Offset::fixed::<3>(),
                                        observed: Offset::fixed::<1>(),
                                    })
                                );
                                let body =
                                    open(&mut app, &root, b"site.css").expect("file before growth");
                                fs::write(&path, REPLACEMENT).expect("grow file");
                                assert_eq!(
                                    collect(&mut app, body),
                                    Err(Error::Changed {
                                        expected: Offset::fixed::<1>(),
                                        observed: Offset::fixed::<3>(),
                                    })
                                );
                                let body = open(&mut app, &root, b"empty").expect("empty file");
                                assert!(collect(&mut app, body).expect("empty bytes").is_empty());
                                assert_eq!(budget.resident(), 0);
                            },
                        )
                        .expect("file shutdown");
                },
                recovery::Policy::new(
                    |event| panic!("unexpected recovery: {event:?}"),
                    |failure: recovery::Recovery<'_, '_>| {
                        eprintln!("native recovery: {:?}", failure.cause());
                        failure.abort()
                    },
                ),
            )
            .as_ref()
            .map_err(|error| error.cause())
            .expect("driver cleanup");
    });
}
