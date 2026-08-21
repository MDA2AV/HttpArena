//! Where the fixtures and the certificate are, for every module that needs one.
//!
//! Note:
//! - Constants, the way the HttpArena entries name /data and /etc/zix-tls. The
//!   entry names the path and the harness guarantees it: there a Dockerfile and
//!   a compose mount put the files in place

pub const DATA_DIR: []const u8 = "/data";

pub const DATASET: []const u8 = "/data/dataset.json";

pub const TLS_CERT: []const u8 = "/etc/zix-tls/server.cert";
pub const TLS_KEY: []const u8 = "/etc/zix-tls/server.key";
