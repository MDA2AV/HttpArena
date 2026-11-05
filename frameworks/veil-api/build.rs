fn main() -> std::io::Result<()> {
    println!("cargo:rerun-if-changed=proto/benchmark.proto");
    veil_build::compile_protos(&["proto/benchmark.proto"], &["proto"])
}
