use std::collections::HashMap;

pub struct StaticEntry {
    pub body: &'static [u8],
    pub br: Option<&'static [u8]>,
    pub gz: Option<&'static [u8]>,
    pub content_type: &'static str,
}

impl StaticEntry {
    pub fn load(dir: &str) -> &'static HashMap<&'static str, StaticEntry> {
        let mut map: HashMap<&'static str, StaticEntry> = HashMap::new();
        let read = match std::fs::read_dir(dir) {
            Ok(r) => r,
            Err(_) => return Box::leak(Box::new(map)),
        };
        for entry in read.flatten() {
            let name_owned = entry.file_name().to_string_lossy().into_owned();
            if name_owned.ends_with(".br") || name_owned.ends_with(".gz") {
                continue;
            }
            let path = entry.path();
            let Ok(body) = std::fs::read(&path) else {
                continue;
            };
            let ct = Self::content_type_for(&name_owned);
            let br = std::fs::read(format!("{dir}/{name_owned}.br"))
                .ok()
                .map(|b| &*Box::leak(b.into_boxed_slice()));
            let gz = std::fs::read(format!("{dir}/{name_owned}.gz"))
                .ok()
                .map(|b| &*Box::leak(b.into_boxed_slice()));
            let name_static: &'static str = Box::leak(name_owned.into_boxed_str());
            let body_static: &'static [u8] = Box::leak(body.into_boxed_slice());
            map.insert(
                name_static,
                StaticEntry {
                    body: body_static,
                    br,
                    gz,
                    content_type: ct,
                },
            );
        }
        Box::leak(Box::new(map))
    }

    pub fn select(&self, accept_encoding: &[u8]) -> (&'static [u8], &'static str) {
        if let Some(br) = self.br
            && Self::accepts(accept_encoding, b"br")
        {
            return (br, "br");
        }
        if let Some(gz) = self.gz
            && Self::accepts(accept_encoding, b"gzip")
        {
            return (gz, "gzip");
        }
        (self.body, "identity")
    }

    fn accepts(header: &[u8], token: &[u8]) -> bool {
        header
            .split(|&b| b == b',')
            .any(|part| part.trim_ascii().starts_with(token))
    }

    fn content_type_for(name: &str) -> &'static str {
        let ext = name.rsplit_once('.').map(|(_, e)| e).unwrap_or("");
        match ext {
            "css" => "text/css",
            "js" => "application/javascript",
            "html" => "text/html; charset=UTF-8",
            "woff2" => "font/woff2",
            "woff" => "font/woff",
            "webp" => "image/webp",
            "png" => "image/png",
            "jpg" | "jpeg" => "image/jpeg",
            "svg" => "image/svg+xml",
            "json" => "application/json",
            "txt" => "text/plain",
            _ => "application/octet-stream",
        }
    }
}
