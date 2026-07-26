fn main() {
    println!("cargo:rerun-if-changed=proto/benchmark.proto");
    sark_grpc_build::compile_protos(&["proto/benchmark.proto"], &["proto"]).unwrap();
}
