use std::io::Write;

use varnish::vcl::StrOrBytes;

fn as_str(s: StrOrBytes<'_>) -> Option<&str> {
    match s {
        StrOrBytes::Utf8(s) => Some(s),
        StrOrBytes::Bytes(_) => None,
    }
}

/// The body is just an integer (e.g. "20"); a stack buffer with a
/// comfortable margin avoids a heap allocation. Excess bytes are dropped.
struct FixedBuf {
    data: [u8; 32],
    len: usize,
}

impl Write for FixedBuf {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let n = buf.len().min(self.data.len() - self.len);
        self.data[self.len..self.len + n].copy_from_slice(&buf[..n]);
        self.len += n;
        Ok(n)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn parse_query_sum(url: &str) -> i64 {
    let qs = match url.split_once('?') {
        Some((_, q)) => q,
        None => return 0,
    };
    qs.split('&')
        .filter_map(|pair| pair.split_once('='))
        .filter_map(|(_, v)| v.trim().parse::<i64>().ok())
        .sum()
}

/// HttpArena benchmark helper: compute the /baseline11 and /baseline2 sum
/// (query params + optional POST body) entirely inside Varnish.
#[varnish::vmod]
mod httparena {
    use varnish::vcl::{Ctx, VclError};

    use super::{as_str, parse_query_sum};

    /// Sum the integer values of all query-string parameters, plus the
    /// request body for POST requests.
    pub fn baseline_sum(ctx: &mut Ctx) -> Result<String, VclError> {
        let (url, is_post) = {
            let req = ctx
                .http_req
                .as_ref()
                .ok_or("baseline_sum: no client request available")?;
            let url = as_str(req.url().ok_or("baseline_sum: request has no URL")?)
                .ok_or("baseline_sum: URL is not valid UTF-8")?
                .to_string();
            let is_post = req.method().and_then(as_str) == Some("POST");
            (url, is_post)
        };

        let mut sum = parse_query_sum(&url);

        if is_post {
            let mut buf = super::FixedBuf {
                data: [0u8; 32],
                len: 0,
            };
            if ctx.req_body(&mut buf).is_ok() {
                if let Ok(n) = std::str::from_utf8(&buf.data[..buf.len])
                    .unwrap_or_default()
                    .trim()
                    .parse::<i64>()
                {
                    sum += n;
                }
            }
        }

        Ok(sum.to_string())
    }
}
