use std::{net::SocketAddr, num::NonZero, path::Path, process::Command};

use httparena_sark::runtime::Worker;

pub fn worker(address: SocketAddr) -> Worker<'static> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let mut boot = super::boot::settings(None, None);
    boot.tcp_bind[0] = address;
    boot.dataset = root.join("data/dataset.json");
    boot.static_root = root.join("data/static");
    Worker {
        connections: NonZero::<usize>::MIN,
        tcp_connections: NonZero::<usize>::MIN,
        database_connections: NonZero::<usize>::MIN,
        h3: None,
        boot,
    }
}

pub fn request(address: SocketAddr, path: &str, body: Option<&[u8]>) -> (u16, Vec<u8>) {
    let mut command = Command::new("curl");
    command.args([
        "--silent",
        "--show-error",
        "--max-time",
        "5",
        "--write-out",
        "\n%{http_code}",
    ]);
    if let Some(body) = body {
        command.args([
            "--header",
            "Content-Type: application/json",
            "--data-binary",
            std::str::from_utf8(body).expect("JSON request"),
        ]);
    }
    let output = command
        .arg(format!("http://{address}{path}"))
        .output()
        .expect("HTTP request");
    assert!(
        output.status.success(),
        "curl failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let mut body = output.stdout;
    let tail = body.len().checked_sub(4).expect("HTTP status");
    assert_eq!(body[tail], b'\n');
    let status = std::str::from_utf8(&body[tail + 1..])
        .expect("HTTP status text")
        .parse()
        .expect("HTTP status code");
    body.truncate(tail);
    (status, body)
}
