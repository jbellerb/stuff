use time::{UtcDateTime, format_description::well_known::Iso8601};

pub struct LesserCopybaraVersionInfo<'a: 'static> {
    pub commit_hash: &'a str,
    pub commit_time: u64,
    pub dirty: bool,
    pub tag: Option<&'a str>,
    pub change_id: Option<&'a str>,
}

impl LesserCopybaraVersionInfo<'_> {
    pub fn version(&self) -> String {
        let tag = self.tag.unwrap_or("0.0.0");
        let short_commit = &self.commit_hash[..7];
        let dirty = if self.dirty { "-dirty" } else { "" };

        let mut build_data = Vec::new();
        if let Some(change_id) = self.change_id {
            build_data.push(change_id[..8].to_string());
        }
        build_data.push(
            UtcDateTime::from_unix_timestamp(self.commit_time as i64)
                .unwrap_or(UtcDateTime::UNIX_EPOCH)
                .format(&Iso8601::DATE)
                .unwrap_or_else(|_| "1970-01-01".to_string()),
        );

        format!(
            "{}-{}{} ({})",
            tag,
            short_commit,
            dirty,
            build_data.join(" ")
        )
    }
}

pub const VERSION: LesserCopybaraVersionInfo = {
    let info = include_str!(env!("LESSER_COPYBARA_VERSION_INFO"));

    let (commit_hash, info) = next_line(info);
    let (change_id, info) = next_line(info);
    let (dirty, info) = next_line(info);
    let (commit_time, info) = next_line(info);
    let (date_tag, _) = next_line(info);

    LesserCopybaraVersionInfo {
        commit_hash,
        commit_time: match u64::from_str_radix(commit_time, 10) {
            Ok(t) => t,
            Err(_) => 0,
        },
        dirty: str_equal(dirty, "dirty"),
        tag: if date_tag.is_empty() {
            None
        } else {
            Some(date_tag)
        },
        change_id: if change_id.is_empty() {
            None
        } else {
            Some(change_id)
        },
    }
};

const fn next_line(s: &str) -> (&str, &str) {
    let mut i = 0;
    while i < s.len() && s.as_bytes()[i] != b'\n' {
        i += 1;
    }

    let (line, mut tail) = s.split_at(i);
    if !tail.is_empty() {
        (_, tail) = tail.split_at(1);
    }

    (line, tail)
}

const fn str_equal<'a>(a: &'a str, b: &'a str) -> bool {
    if a.len() != b.len() {
        return false;
    }

    let mut i = 0;
    while i < a.len() {
        if a.as_bytes()[i] != b.as_bytes()[i] {
            return false;
        }
        i += 1;
    }

    true
}
