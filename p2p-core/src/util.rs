//! Pure helpers (no I/O, no librqbit) so they are unit-testable on any host.

#[derive(Debug, PartialEq, Eq)]
pub enum RangeSpec {
    Full,
    Partial(u64, u64), // inclusive start..=end
    Unsatisfiable,
}

/// Parses a single-range `Range: bytes=...` header. Multi-range / malformed headers fall back to Full (RFC 9110 allows ignoring).
pub fn parse_range(h: &str, len: u64) -> RangeSpec {
    let Some(spec) = h.trim().strip_prefix("bytes=") else { return RangeSpec::Full };
    if spec.contains(',') || len == 0 {
        return if len == 0 { RangeSpec::Unsatisfiable } else { RangeSpec::Full };
    }
    let Some((a, b)) = spec.split_once('-') else { return RangeSpec::Full };
    let (a, b) = (a.trim(), b.trim());
    if a.is_empty() {
        let Ok(n) = b.parse::<u64>() else { return RangeSpec::Full };
        if n == 0 {
            return RangeSpec::Unsatisfiable;
        }
        return RangeSpec::Partial(len.saturating_sub(n), len - 1);
    }
    let Ok(s) = a.parse::<u64>() else { return RangeSpec::Full };
    if s >= len {
        return RangeSpec::Unsatisfiable;
    }
    let e = if b.is_empty() {
        len - 1
    } else {
        match b.parse::<u64>() {
            Ok(e) => e.min(len - 1),
            Err(_) => return RangeSpec::Full,
        }
    };
    if e < s { RangeSpec::Full } else { RangeSpec::Partial(s, e) }
}

const VIDEO_EXT: &[&str] = &["mkv", "mp4", "m4v", "mov", "avi", "webm", "wmv", "flv", "ts", "m2ts"];

pub fn ext_of(name: &str) -> String {
    name.rsplit('.').next().filter(|e| *e != name).unwrap_or("").to_ascii_lowercase()
}

/// `want` wins if in range; otherwise the largest video file; otherwise the largest file.
pub fn pick_file(files: &[(String, u64)], want: Option<u32>) -> Option<usize> {
    if let Some(w) = want {
        return ((w as usize) < files.len()).then_some(w as usize);
    }
    let largest = |video_only: bool| {
        files
            .iter()
            .enumerate()
            .filter(|(_, (n, _))| !video_only || VIDEO_EXT.contains(&ext_of(n).as_str()))
            .max_by_key(|(_, (_, l))| *l)
            .map(|(i, _)| i)
    };
    largest(true).or_else(|| largest(false))
}

pub fn mime_for(name: &str) -> &'static str {
    match ext_of(name).as_str() {
        "mp4" | "m4v" => "video/mp4",
        "mkv" => "video/x-matroska",
        "webm" => "video/webm",
        "mov" => "video/quicktime",
        "avi" => "video/x-msvideo",
        "ts" | "m2ts" => "video/mp2t",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ranges() {
        assert_eq!(parse_range("bytes=0-", 100), RangeSpec::Partial(0, 99));
        assert_eq!(parse_range("bytes=10-20", 100), RangeSpec::Partial(10, 20));
        assert_eq!(parse_range("bytes=90-500", 100), RangeSpec::Partial(90, 99));
        assert_eq!(parse_range("bytes=-10", 100), RangeSpec::Partial(90, 99));
        assert_eq!(parse_range("bytes=-500", 100), RangeSpec::Partial(0, 99));
        assert_eq!(parse_range("bytes=100-", 100), RangeSpec::Unsatisfiable);
        assert_eq!(parse_range("bytes=0-1,5-6", 100), RangeSpec::Full);
        assert_eq!(parse_range("junk", 100), RangeSpec::Full);
        assert_eq!(parse_range("bytes=20-10", 100), RangeSpec::Full);
    }
    #[test]
    fn picking() {
        let f = vec![("a.nfo".into(), 5), ("b.mkv".into(), 900), ("c.mp4".into(), 100), ("d.bin".into(), 9999)];
        assert_eq!(pick_file(&f, None), Some(1));
        assert_eq!(pick_file(&f, Some(2)), Some(2));
        assert_eq!(pick_file(&f, Some(9)), None);
        assert_eq!(pick_file(&[("x.bin".into(), 3)], None), Some(0));
    }
}
