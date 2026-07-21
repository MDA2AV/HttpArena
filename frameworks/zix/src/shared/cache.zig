//! Engine response-cache TTL (cache_ttl_ms), long-lived since the dataset is
//! immutable and each key renders once per run.

const std = @import("std");

/// Long TTL: the dataset is immutable, each key is built once per run.
pub const TTL_MS: u32 = (60 * 1_000) * 6;
