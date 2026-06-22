pub struct Body;

impl Body {
    pub fn str_field<'a>(body: &'a [u8], key: &[u8]) -> Option<&'a [u8]> {
        let after_colon = Self::find_key(body, key)?;
        let rest = &body[after_colon..];
        let q_start = rest.iter().position(|&b| !b.is_ascii_whitespace())?;
        if rest[q_start] != b'"' {
            return None;
        }
        let value_start = q_start + 1;
        let mut i = value_start;
        while i < rest.len() {
            match rest[i] {
                b'\\' => i = i.saturating_add(2),
                b'"' => return Some(&rest[value_start..i]),
                _ => i += 1,
            }
        }
        None
    }

    pub fn i64_field(body: &[u8], key: &[u8]) -> Option<i64> {
        let after_colon = Self::find_key(body, key)?;
        let rest = &body[after_colon..];
        let v_start = rest.iter().position(|&b| !b.is_ascii_whitespace())?;
        let mut i = v_start;
        let neg = if rest[i] == b'-' {
            i += 1;
            true
        } else {
            false
        };
        let digits_start = i;
        let mut acc: i64 = 0;
        while i < rest.len() && rest[i].is_ascii_digit() {
            acc = acc.checked_mul(10)?.checked_add((rest[i] - b'0') as i64)?;
            i += 1;
        }
        if i == digits_start {
            return None;
        }
        Some(if neg { -acc } else { acc })
    }

    fn find_key(body: &[u8], key: &[u8]) -> Option<usize> {
        let mut i = 0usize;
        while i + key.len() + 2 < body.len() {
            if body[i] == b'"'
                && body.get(i + 1..i + 1 + key.len()) == Some(key)
                && body.get(i + 1 + key.len()) == Some(&b'"')
            {
                let mut j = i + 2 + key.len();
                while j < body.len() && body[j].is_ascii_whitespace() {
                    j += 1;
                }
                if j < body.len() && body[j] == b':' {
                    return Some(j + 1);
                }
            }
            i += 1;
        }
        None
    }
}
