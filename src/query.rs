use crate::{
    Hit, Mode, Result, document_stamp_sql, fts_phrase, name_fast, norm, read_document_stamp,
    row_hit, short_snippet,
};
use rusqlite::{Connection, params};

#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Terms {
    words: Vec<String>,
    suffix: Option<String>,
    conflicting_suffixes: bool,
    quoted: bool,
}

impl Terms {
    /// The single unquoted token path retains its existing ranking and fast indexes.
    pub(super) fn parse(query: &str) -> Option<Self> {
        if !query.chars().any(|c| c.is_whitespace() || quote(c)) && extension(query).is_none() {
            return None;
        }
        let mut terms = Self::default();
        let mut current = String::new();
        let mut in_quote = false;
        let mut chars = query.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '\\'
                && chars
                    .peek()
                    .is_some_and(|&next| quote(next) || next == '\\')
            {
                current.push(chars.next().unwrap());
            } else if quote(c) {
                terms.push(&mut current, in_quote);
                in_quote = !in_quote;
                terms.quoted = true;
            } else if c.is_whitespace() && !in_quote {
                terms.push(&mut current, false);
            } else {
                current.push(c);
            }
        }
        // During typing, an opening quote treats the remaining input as a phrase.
        terms.push(&mut current, in_quote);
        Some(terms)
    }

    fn push(&mut self, current: &mut String, quoted: bool) {
        let word = std::mem::take(current);
        if word.trim().is_empty() {
            return;
        }
        if !quoted && let Some(ext) = extension(&word) {
            let suffix = format!(".{ext}");
            if let Some(previous) = &self.suffix {
                self.conflicting_suffixes |= previous != &suffix;
            } else {
                self.suffix = Some(suffix);
            }
        } else if !self.words.contains(&word) {
            self.words.push(word);
        }
    }

    pub(super) fn permits_semantic(&self) -> bool {
        self.suffix.is_none() && !self.quoted
    }
}

fn quote(c: char) -> bool {
    matches!(c, '"' | '“' | '”')
}

fn extension(word: &str) -> Option<&str> {
    let ext = word.strip_prefix('.').unwrap_or(word);
    // These common bare tokens are recognizable as filename extensions. The
    // dotted form also supports types whose bare spelling is an ordinary word.
    let common = matches!(
        ext,
        "pdf"
            | "doc"
            | "docx"
            | "ppt"
            | "pptx"
            | "xls"
            | "xlsx"
            | "txt"
            | "md"
            | "markdown"
            | "rtf"
            | "odt"
            | "ods"
            | "odp"
            | "csv"
            | "tsv"
            | "json"
            | "yaml"
            | "yml"
            | "xml"
            | "html"
            | "htm"
            | "png"
            | "jpg"
            | "jpeg"
            | "gif"
            | "webp"
            | "heic"
            | "svg"
            | "tiff"
            | "tif"
            | "bmp"
            | "mp3"
            | "wav"
            | "m4a"
            | "aac"
            | "flac"
            | "mp4"
            | "mov"
            | "mkv"
            | "avi"
            | "webm"
            | "zip"
            | "rar"
            | "7z"
            | "gz"
            | "tar"
            | "dmg"
    );
    (common
        || (word.starts_with('.')
            && matches!(
                ext,
                "key" | "pages" | "numbers" | "go" | "js" | "ts" | "rs" | "py" | "log"
            )))
    .then_some(ext)
}

pub fn allows_semantic(query: &str) -> bool {
    Terms::parse(&norm(query.trim())).is_none_or(|terms| terms.permits_semantic())
}

const SUFFIX_FILTER: &str = "(?2 IS NULL OR (i.kind='file' AND length(i.display)>length(?2)
                             AND lower(substr(i.path,-length(?2)))=?2))";

fn anchors(terms: impl Iterator<Item = impl AsRef<str>>) -> String {
    let mut phrases: Vec<_> = terms
        .filter_map(|term| {
            let term = term.as_ref();
            (term.chars().count() >= 3 && !term.contains('\0')).then(|| fts_phrase(term))
        })
        .collect();
    // Stable FTS evaluation and ranking for permutations of the same words.
    phrases.sort_unstable();
    phrases.join(" AND ")
}

pub(super) fn search(
    conn: &Connection,
    terms: &Terms,
    mode: Mode,
    limit: usize,
) -> Result<Vec<Hit>> {
    if terms.conflicting_suffixes || (terms.words.is_empty() && terms.suffix.is_none()) {
        return Ok(Vec::new());
    }
    // Across the two lexical lanes, use the same committed availability
    // snapshot. Reusing a caller's transaction avoids nested BEGIN failures.
    let tx = conn
        .is_autocommit()
        .then(|| conn.unchecked_transaction())
        .transpose()?;
    let snapshot = tx.as_deref().unwrap_or(conn);
    let words = serde_json::to_string(&terms.words)?;
    let names = if matches!(mode, Mode::Name | Mode::All) {
        find_names(snapshot, terms, &words, limit)?
    } else {
        Vec::new()
    };
    let mut hits = names;
    if matches!(mode, Mode::Text | Mode::All) && hits.len() < limit && !terms.words.is_empty() {
        let content = find_text(snapshot, terms, &words, limit + hits.len())?;
        let mut seen: std::collections::HashSet<_> =
            hits.iter().map(|hit| hit.path.clone()).collect();
        for hit in content {
            if seen.insert(hit.path.clone()) {
                hits.push(hit);
            }
            if hits.len() == limit {
                break;
            }
        }
    }
    if let Some(tx) = tx {
        tx.commit()?;
    }
    Ok(hits)
}

fn find_names(conn: &Connection, terms: &Terms, words: &str, limit: usize) -> Result<Vec<Hit>> {
    let anchor = anchors(terms.words.iter().chain(terms.suffix.iter()));
    let (from, input) = if !anchor.is_empty() {
        (
            "name_fts CROSS JOIN item i ON i.id=name_fts.rowid AND name_fts MATCH ?3",
            anchor,
        )
    } else if let Some(paths) = name_fast::short_han_seed(conn, &terms.words)? {
        (
            "json_each(?3) c CROSS JOIN item i ON i.path=c.value",
            serde_json::to_string(&paths)?,
        )
    } else {
        ("item i", anchor)
    };
    let field_rank = "CASE
        WHEN i.name=t.value THEN 0
        WHEN instr(i.name,t.value)=1 THEN 1
        WHEN instr(i.name,t.value)>0 THEN 2
        WHEN instr(i.full,t.value)>0 OR instr(i.initials,t.value)>0 THEN 3
        WHEN instr(i.searchable_path,t.value)>0 THEN 4
        ELSE 5 END";
    let sql = format!(
        "SELECT i.path,i.display,i.kind,i.availability,
                coalesce((SELECT max({field_rank}) FROM json_each(?1) t),0) AS worst,
                coalesce((SELECT sum({field_rank}) FROM json_each(?1) t),0) AS total
         FROM {from}
         WHERE ?3 IS NOT NULL AND i.availability<>'unverified' AND {SUFFIX_FILTER}
           AND NOT EXISTS (SELECT 1 FROM json_each(?1) t WHERE {field_rank}=5)
         ORDER BY worst,total,length(i.display),i.path LIMIT ?4"
    );
    let mut stmt = conn.prepare_cached(&sql)?;
    let rows = stmt.query_map(params![words, terms.suffix, input, limit as i64], |row| {
        let reason = match row.get::<_, i64>(4)? {
            4 => "path",
            3 => "pinyin",
            _ => "name",
        };
        row_hit(row, reason)
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}

fn find_text(conn: &Connection, terms: &Terms, words: &str, limit: usize) -> Result<Vec<Hit>> {
    let anchor = anchors(terms.words.iter());
    let (stamp, state_join) = document_stamp_sql(conn)?;
    let (from, order) = if anchor.is_empty() {
        // Start at documents, even when an index on item.path could satisfy ORDER BY.
        ("document d CROSS JOIN item i ON i.id=d.id", "i.path")
    } else {
        (
            "content_fts CROSS JOIN document d ON d.id=content_fts.rowid
             CROSS JOIN item i ON i.id=d.id AND content_fts MATCH ?3",
            "rank,i.path",
        )
    };
    let sql = format!(
        "SELECT i.path,i.display,i.kind,i.availability,d.body,{stamp} AS document_stamp
         FROM {from} {state_join}
         WHERE ?3 IS NOT NULL AND i.availability<>'unverified' AND {SUFFIX_FILTER}
           AND NOT EXISTS (SELECT 1 FROM json_each(?1) t WHERE instr(d.normalized,t.value)=0)
         ORDER BY {order} LIMIT ?4"
    );
    let mut stmt = conn.prepare_cached(&sql)?;
    let rows = stmt.query_map(params![words, terms.suffix, anchor, limit as i64], |row| {
        let mut hit = row_hit(row, "text")?;
        let text: String = row.get(4)?;
        hit.snippet = Some(short_snippet(&text, &terms.words[0]));
        hit.document_stamp = read_document_stamp(row)?;
        Ok(hit)
    })?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}
