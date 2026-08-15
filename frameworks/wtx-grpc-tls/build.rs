use pb_rs::{ConfigBuilder, types::FileDescriptor};
use std::{
  fs::{DirBuilder, remove_dir_all},
  path::Path,
};

fn main() {
  let cmd = std::env::var("CARGO_MANIFEST_DIR").unwrap();
  let in_dir = Path::new(&cmd).join("proto");
  let out_dir = Path::new(&std::env::var("OUT_DIR").unwrap()).join("proto");
  if out_dir.exists() {
    remove_dir_all(&out_dir).unwrap();
  }
  DirBuilder::new().create(&out_dir).unwrap();
  FileDescriptor::run(
    &ConfigBuilder::new(
      &[Path::new(&cmd).join("proto/benchmark.proto").as_path()],
      None,
      Some(&out_dir.as_path()),
      &[in_dir.as_path()],
    )
    .unwrap()
    .build(),
  )
  .unwrap();
}
