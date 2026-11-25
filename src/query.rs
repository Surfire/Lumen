use crate::{
    Hit, Mode, Result, document_stamp_sql, fts_phrase, name_fast, norm, pinyin,
    read_document_stamp, row_hit, short_snippet,
};
use rusqlite::{Connection, params};

#[derive(Debug, Default, PartialEq, Eq)]
pub(super) struct Terms {
    pub words: Vec<String>,
    pub suffix: Option<String>,
    pub kind: Option<Kind>,
    pub paths: Vec<String>,
    pub conflicting: bool,
    quoted: bool,
}

impl Terms {
    /// The single unquoted token path retains its existing ranking and fast indexes.
    pub(super) fn parse(query: &str) -> Option<Self> {
        if !query.chars().any(|c| c.is_whitespace() || quote(c))
            && explicit_extension(query).is_none()
            && Kind::parse(query).is_none()
            && path_prefix(query).is_none()
            && pinyin::legacy(query).is_none()
        {
            return None;
        }
        let mut terms = Self::default();
        let mut tokens = Vec::new();
        let mut current = String::new();
        let mut push = |current: &mut String, quoted| {
            if !current.trim().is_empty() {
                tokens.push((std::mem::take(current), quoted));
            } else {
                current.clear();
            }
        };
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
                push(&mut current, in_quote);
                in_quote = !in_quote;
                terms.quoted = true;
            } else if c.is_whitespace() && !in_quote {
                push(&mut current, false);
            } else {
                current.push(c);
            }
        }
        // During typing, an opening quote treats the remaining input as a phrase.
        push(&mut current, in_quote);
        // Bare extensions are shorthand only alongside a search term. In
        // particular `json` must search names/text, not list every JSON file.
        let has_search_word = tokens.iter().any(|(word, quoted)| {
            *quoted || (explicit_extension(word).is_none() && !common_extension(word))
        });
        for (word, quoted) in tokens {
            if !quoted && let Some(kind) = Kind::parse(&word) {
                terms.conflicting |= terms.kind.replace(kind).is_some_and(|prior| prior != kind);
                continue;
            }
            if let Some(path) = path_prefix(&word) {
                terms.paths.push(path);
                continue;
            }
            let ext = if quoted {
                None
            } else {
                explicit_extension(&word).or_else(|| {
                    (has_search_word && common_extension(&word)).then_some(word.as_str())
                })
            };
            if let Some(ext) = ext {
                let suffix = format!(".{ext}");
                if let Some(previous) = &terms.suffix {
                    terms.conflicting |= previous != &suffix;
                } else {
                    terms.suffix = Some(suffix);
                }
            } else if !terms.words.contains(&word) {
                terms.words.push(word);
            }
        }
        Some(terms)
    }

    pub(super) fn is_empty(&self) -> bool {
        self.words.is_empty()
            && self.suffix.is_none()
            && self.kind.is_none()
            && self.paths.is_empty()
    }

    pub(super) fn permits_semantic(&self) -> bool {
        self.suffix.is_none() && self.kind.is_none() && self.paths.is_empty() && !self.quoted
    }

    fn filters(&self) -> String {
        let mut sql = self.kind.map_or_else(String::new, Kind::sql_filter);
        if !self.paths.is_empty() {
            sql.push_str(
                " AND NOT EXISTS (SELECT 1 FROM json_each(?5) p WHERE
                instr(i.searchable_path,p.value)<>1 OR
                (substr(p.value,-1)<>'/' AND i.searchable_path<>p.value
                 AND substr(i.searchable_path,length(p.value)+1,1)<>'/'))",
            );
        }
        sql
    }
}

fn path_prefix(word: &str) -> Option<String> {
    if word.starts_with('/') {
        #[cfg(target_os = "macos")]
        if ["/tmp", "/var"].iter().any(|alias| {
            word == *alias
                || word
                    .strip_prefix(alias)
                    .is_some_and(|rest| rest.starts_with('/'))
        }) {
            return Some(format!("/private{word}"));
        }
        Some(word.to_owned())
    } else {
        let relative = word.strip_prefix("~/")?;
        let home = std::env::var_os("HOME")?;
        let home = crate::absolute(std::path::Path::new(&home)).ok()?;
        Some(format!(
            "{}/{}",
            norm(home.to_str()?.trim_end_matches('/')),
            relative
        ))
    }
}

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Kind {
    App,
    Folder,
    Doc,
    Image,
    Video,
    Audio,
    Code,
    Archive,
    Other,
}

impl Kind {
    const FILE_KINDS: [Kind; 6] = [
        Self::Doc,
        Self::Image,
        Self::Video,
        Self::Audio,
        Self::Code,
        Self::Archive,
    ];

    fn parse(word: &str) -> Option<Self> {
        Some(match word.strip_prefix("kind:")? {
            "doc" => Self::Doc,
            "image" => Self::Image,
            "video" => Self::Video,
            "audio" => Self::Audio,
            "code" => Self::Code,
            "archive" => Self::Archive,
            "folder" => Self::Folder,
            "app" => Self::App,
            _ => return None,
        })
    }

    fn extensions(self) -> &'static [&'static str] {
        match self {
            Self::Doc => &[
                "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "md", "markdown", "rtf",
                "odt", "ods", "odp", "csv", "tsv", "pages", "numbers", "key", "epub",
            ],
            Self::Image => &[
                "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "svg", "tiff", "tif", "bmp",
                "ico", "raw", "dng", "avif",
            ],
            Self::Video => &[
                "mp4", "mov", "mkv", "avi", "webm", "m4v", "mpeg", "mpg", "wmv",
            ],
            Self::Audio => &[
                "mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff", "aif", "opus", "caf",
            ],
            Self::Code => &[
                "rs", "swift", "py", "js", "ts", "jsx", "tsx", "c", "h", "cpp", "hpp", "m", "mm",
                "go", "rb", "java", "kt", "sh", "zsh", "html", "htm", "css", "scss", "json",
                "yaml", "yml", "xml", "toml", "sql", "php", "lua",
            ],
            Self::Archive => &[
                "zip", "rar", "7z", "gz", "tar", "dmg", "bz2", "xz", "tgz", "pkg",
            ],
            _ => &[],
        }
    }

    pub fn classify(name: &str, directory: bool) -> Self {
        if directory {
            return if name.ends_with(".app") {
                Self::App
            } else {
                Self::Folder
            };
        }
        if let Some((_, extension)) = name.rsplit_once('.') {
            return Self::FILE_KINDS
                .into_iter()
                .find(|kind| kind.extensions().contains(&extension))
                .unwrap_or(Self::Other);
        }
        Self::Other
    }

    fn sql_filter(self) -> String {
        match self {
            Self::App => " AND i.kind='directory' AND lower(i.display) GLOB '*.app'".to_owned(),
            Self::Folder => {
                " AND i.kind='directory' AND lower(i.display) NOT GLOB '*.app'".to_owned()
            }
            _ => {
                let tests = self
                    .extensions()
                    .iter()
                    .map(|ext| format!("lower(i.display) GLOB '*.{ext}'"))
                    .collect::<Vec<_>>()
                    .join(" OR ");
                format!(" AND i.kind='file' AND ({tests})")
            }
        }
    }
}

fn quote(c: char) -> bool {
    matches!(c, '"' | '“' | '”')
}

fn explicit_extension(word: &str) -> Option<&str> {
    let ext = word
        .strip_prefix('.')
        .or_else(|| word.strip_prefix("ext:"))?;
    (!ext.is_empty() && ext.bytes().all(|c| c.is_ascii_alphanumeric())).then_some(ext)
}

fn common_extension(word: &str) -> bool {
    matches!(
        word,
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
    )
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
    cached_names: Option<Vec<Hit>>,
) -> Result<Vec<Hit>> {
    if terms.conflicting || terms.is_empty() {
        return Ok(Vec::new());
    }
    // Across the two lexical lanes, use the same committed availability
    // snapshot. Reusing a caller's transaction avoids nested BEGIN failures.
    let tx = conn
        .is_autocommit()
        .then(|| conn.unchecked_transaction())
        .transpose()?;
    let snapshot = tx.as_deref().unwrap_or(conn);
    let mut hits = if let Some(names) = cached_names {
        names
    } else if matches!(mode, Mode::Name | Mode::All) {
        find_names(snapshot, terms, limit)?
    } else {
        Vec::new()
    };
    if matches!(mode, Mode::Text | Mode::All) && hits.len() < limit && !terms.words.is_empty() {
        let words = serde_json::to_string(&terms.words)?;
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

fn find_names(conn: &Connection, terms: &Terms, limit: usize) -> Result<Vec<Hit>> {
    #[derive(serde::Serialize)]
    struct Word<'a> {
        word: &'a str,
        legacy: Option<pinyin::LegacyReading>,
    }
    let aliases: Vec<_> = terms
        .words
        .iter()
        .map(|word| Word {
            word,
            legacy: pinyin::legacy(word),
        })
        .collect();
    let has_alias = aliases.iter().any(|term| term.legacy.is_some());
    let words = if has_alias {
        serde_json::to_string(&aliases)?
    } else {
        serde_json::to_string(&terms.words)?
    };
    let anchor = if has_alias {
        let mut phrases: Vec<_> = aliases
            .iter()
            .filter(|term| term.word.chars().count() >= 3 && !term.word.contains('\0'))
            .map(|term| {
                let phrase = fts_phrase(term.word);
                if let Some(legacy) = &term.legacy {
                    format!("({phrase} OR {})", fts_phrase(&legacy.key))
                } else {
                    phrase
                }
            })
            .collect();
        if let Some(suffix) = &terms.suffix {
            phrases.push(fts_phrase(suffix));
        }
        phrases.sort_unstable();
        phrases.join(" AND ")
    } else {
        anchors(terms.words.iter().chain(terms.suffix.iter()))
    };
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
    let term = if has_alias {
        "(t.value ->> '$.word')"
    } else {
        "t.value"
    };
    let legacy = if has_alias {
        " OR ((CASE WHEN (t.value ->> '$.legacy.initials') THEN
                  instr(i.initials, t.value ->> '$.legacy.key') ELSE
                  instr(i.full, t.value ->> '$.legacy.key') END) > 0
               AND NOT EXISTS (SELECT 1 FROM json_each(t.value,'$.legacy.phrases') c
                               WHERE instr(i.name,c.value)=0))"
    } else {
        ""
    };
    let field_rank = format!(
        "CASE
        WHEN i.name={term} THEN 0
        WHEN instr(i.name,{term})=1 THEN 1
        WHEN instr(i.name,{term})>0 THEN 2
        WHEN instr(i.full,{term})>0 OR instr(i.initials,{term})>0{legacy} THEN 3
        WHEN instr(i.searchable_path,{term})>0 THEN 4
        ELSE 5 END"
    );
    let filters = terms.filters();
    let paths = serde_json::to_string(&terms.paths)?;
    let sql = format!(
        "SELECT i.path,i.display,i.kind,i.availability,
                coalesce((SELECT max({field_rank}) FROM json_each(?1) t),0) AS worst,
                coalesce((SELECT sum({field_rank}) FROM json_each(?1) t),0) AS total
         FROM {from}
         WHERE ?3 IS NOT NULL AND ?5 IS NOT NULL AND i.availability<>'unverified' AND {SUFFIX_FILTER}
           {filters} AND NOT EXISTS (SELECT 1 FROM json_each(?1) t WHERE {field_rank}=5)
         ORDER BY worst,total,length(i.display),i.path LIMIT ?4"
    );
    let mut stmt = conn.prepare_cached(&sql)?;
    let rows = stmt.query_map(
        params![words, terms.suffix, input, limit as i64, paths],
        |row| {
            let reason = match row.get::<_, i64>(4)? {
                4 => "path",
                3 => "pinyin",
                _ => "name",
            };
            row_hit(row, reason)
        },
    )?;
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
    let filters = terms.filters();
    let paths = serde_json::to_string(&terms.paths)?;
    let sql = format!(
        "SELECT i.path,i.display,i.kind,i.availability,d.body,{stamp} AS document_stamp,d.id
         FROM {from} {state_join}
         WHERE ?3 IS NOT NULL AND ?5 IS NOT NULL AND i.availability<>'unverified' AND {SUFFIX_FILTER}
           {filters} AND NOT EXISTS (SELECT 1 FROM json_each(?1) t WHERE instr(d.normalized,t.value)=0)
         ORDER BY {order} LIMIT ?4"
    );
    let mut stmt = conn.prepare_cached(&sql)?;
    let rows = stmt.query_map(
        params![words, terms.suffix, anchor, limit as i64, paths],
        |row| {
            let mut hit = row_hit(row, "text")?;
            let text: String = row.get(4)?;
            hit.document_stamp = read_document_stamp(row)?;
            let page = if hit.document_stamp.is_some()
                && crate::index::DocumentKind::for_path(std::path::Path::new(&hit.path))
                    == Some(crate::index::DocumentKind::Pdf)
            {
                crate::content::matching_page(conn, row.get(6)?, &text, &terms.words)?
            } else {
                None
            };
            hit.pdf_page = page.map(|(number, _)| number);
            hit.snippet = Some(short_snippet(
                page.map_or(&text, |(_, page)| page),
                &terms.words[0],
            ));
            Ok(hit)
        },
    )?;
    Ok(rows.collect::<rusqlite::Result<_>>()?)
}
