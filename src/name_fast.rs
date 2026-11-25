use crate::{Hit, Result, fts_phrase, open_read, row_hit};
use rusqlite::{Connection, params};
use std::{
    collections::HashMap,
    mem::size_of,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

// SQLite remains the query path while building, for larger indexes, and for
// queries whose folding needs SQLite's trigram tokenizer.
const MAX_ROWS: usize = 500_000;
const MAX_INDEX_BYTES: usize = 120 * 1024 * 1024;
const REBUILD_DELAY: Duration = Duration::from_millis(200);
const OVER_BUDGET_DELAY: Duration = Duration::from_secs(10);

pub(super) const CREATE_NAME_ORDER: &str =
    "CREATE INDEX IF NOT EXISTS item_name_order ON item(name, length(display), path)
     WHERE availability<>'unverified';";

// Exact names have rank 0. Their fixed first key lets the index return rows
// already ordered by name length and path. For prefixes the index scans only
// the matching name range and sorts its narrow keys before reading the hits.
const ORDERED_PREFIX: &str = "
    WITH exact AS MATERIALIZED (
        SELECT id, length(display) AS width, path FROM item INDEXED BY item_name_order
        WHERE availability<>'unverified' AND name=?1
        ORDER BY length(display),path LIMIT ?3
    ), prefix AS MATERIALIZED (
        SELECT id, length(display) AS width, path FROM item INDEXED BY item_name_order
        WHERE availability<>'unverified' AND name>?1 AND name<?2
        ORDER BY length(display),path LIMIT (?3 - (SELECT count(*) FROM exact))
    ), matches AS (
        SELECT id, width, path, 0 AS rank FROM exact
        UNION ALL
        SELECT id, width, path, 1 AS rank FROM prefix
    )
    SELECT i.path,i.display,i.kind,i.availability
    FROM matches m JOIN item i ON i.id=m.id ORDER BY m.rank,m.width,m.path";

fn prefix_end(query: &str) -> Option<String> {
    let (end, ch) = query.char_indices().rfind(|&(_, c)| c != char::MAX)?;
    let next = char::from_u32(ch as u32 + 1).unwrap_or('\u{e000}');
    let mut upper = query[..end].to_owned();
    upper.push(next);
    Some(upper)
}

fn ranked_prefix(conn: &Connection, query: &str, limit: usize) -> Result<Option<Vec<Hit>>> {
    if query.contains(['\0', '/']) || !literal_query(query) {
        return Ok(None);
    }
    let Some(upper) = prefix_end(query) else {
        return Ok(None);
    };
    let mut stmt = match conn.prepare_cached(ORDERED_PREFIX) {
        Ok(stmt) => stmt,
        Err(_) => {
            // Older indexes are readable before a writer installs the optional
            // index. A running reader sees it on the next successful prepare.
            let installed: bool = conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name='item_name_order' AND type='index')",
                [],
                |row| row.get(0),
            )?;
            if !installed {
                return Ok(None);
            }
            conn.prepare_cached(ORDERED_PREFIX)?
        }
    };
    let hits = stmt
        .query_map(params![query, upper, limit as i64], |row| {
            row_hit(row, "name")
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    // Lower-ranked substring, pinyin and path hits cannot displace a full
    // page of exact or prefix hits. When they could, search all fields.
    Ok((hits.len() == limit).then_some(hits))
}

pub(super) fn search_disk(conn: &Connection, query: &str, limit: usize) -> Result<Vec<Hit>> {
    if let Some(hits) = ranked_prefix(conn, query, limit)? {
        return Ok(hits);
    }
    const LONG: &str = "SELECT i.path,i.display,i.kind,i.availability,CASE WHEN instr(i.name,?2)>0 THEN 'name' WHEN instr(i.full,?2)>0 OR instr(i.initials,?2)>0 THEN 'pinyin' ELSE 'path' END FROM name_fts JOIN item i ON i.id=name_fts.rowid WHERE name_fts MATCH ?1 AND i.availability<>'unverified' ORDER BY CASE WHEN i.name=?2 THEN 0 WHEN instr(i.name,?2)=1 THEN 1 WHEN instr(i.name,?2)>0 THEN 2 WHEN instr(i.full,?2)>0 OR instr(i.initials,?2)>0 THEN 3 ELSE 4 END,length(i.display),i.path LIMIT ?3";
    const SHORT: &str = "SELECT i.path,i.display,i.kind,i.availability,CASE WHEN instr(i.name,?2)>0 THEN 'name' WHEN instr(i.full,?2)>0 OR instr(i.initials,?2)>0 THEN 'pinyin' ELSE 'path' END FROM item i WHERE ?1 IS NOT NULL AND i.availability<>'unverified' AND (instr(i.name,?2)>0 OR instr(i.full,?2)>0 OR instr(i.initials,?2)>0 OR instr(i.searchable_path,?2)>0) ORDER BY CASE WHEN i.name=?2 THEN 0 WHEN instr(i.name,?2)=1 THEN 1 WHEN instr(i.name,?2)>0 THEN 2 WHEN instr(i.full,?2)>0 OR instr(i.initials,?2)>0 THEN 3 ELSE 4 END,length(i.display),i.path LIMIT ?3";
    let mut stmt = conn.prepare_cached(if query.chars().count() >= 3 {
        LONG
    } else {
        SHORT
    })?;
    let hits = stmt.query_map(params![fts_phrase(query), query, limit as i64], |row| {
        row_hit(row, &row.get::<_, String>(4)?)
    })?;
    Ok(hits.collect::<rusqlite::Result<_>>()?)
}

struct Build {
    cancel: Arc<AtomicBool>,
    worker: JoinHandle<Result<Option<NameIndex>>>,
}

pub(super) struct NameFast {
    db: PathBuf,
    generation: Option<i64>,
    index: Option<NameIndex>,
    build: Option<Build>,
    next_build: Instant,
}

pub(super) fn data_version(conn: &Connection) -> Result<i64> {
    Ok(conn.pragma_query_value(None, "data_version", |row| row.get(0))?)
}

impl NameFast {
    pub(super) fn new(db: &Path, conn: &Connection) -> Self {
        let mut fast = Self {
            db: db.to_owned(),
            generation: None,
            index: None,
            build: None,
            next_build: Instant::now(),
        };
        if let Ok(version) = data_version(conn) {
            fast.start(version);
        }
        fast
    }

    pub(super) fn search(
        &mut self,
        conn: &Connection,
        query: &str,
        limit: usize,
    ) -> Result<Option<(i64, Vec<Hit>)>> {
        let version = data_version(conn)?;
        let current = self.generation == Some(version);
        if let Some(build) = &self.build {
            if !current {
                build.cancel.store(true, Ordering::Relaxed);
            }
            if build.worker.is_finished() {
                let build = self.build.take().unwrap();
                let result = build.worker.join();
                if current {
                    self.index = result.ok().and_then(Result::ok).flatten();
                    if self.index.is_none() {
                        self.next_build = Instant::now() + OVER_BUDGET_DELAY;
                    }
                }
            }
        }
        if !current && self.build.is_none() && Instant::now() >= self.next_build {
            self.start(version);
        }
        if !current {
            return Ok(None);
        }
        if query.contains('\0') || !literal_query(query) {
            return Ok(None);
        }
        Ok(self
            .index
            .as_ref()
            .map(|index| (version, index.search(query, limit))))
    }

    fn start(&mut self, version: i64) {
        let db = self.db.clone();
        let stale = self.index.take();
        let cancel = Arc::new(AtomicBool::new(false));
        let cancellation = Arc::clone(&cancel);
        self.generation = Some(version);
        self.next_build = Instant::now() + REBUILD_DELAY;
        self.build = thread::Builder::new()
            .name("lumen-names".to_owned())
            .spawn(move || {
                drop(stale);
                NameIndex::load(&db, &cancellation)
            })
            .ok()
            .map(|worker| Build { cancel, worker });
    }
}

impl Drop for NameFast {
    fn drop(&mut self) {
        if let Some(build) = &self.build {
            build.cancel.store(true, Ordering::Relaxed);
        }
    }
}

fn literal_query(query: &str) -> bool {
    if query.is_ascii() || query.chars().count() < 3 {
        return true;
    }
    // After Lumen's NFKC and lowercase pass, FTS5's additional case folding
    // cannot introduce ASCII or Han in these ranges. Keep the FTS path for
    // other scripts: a literal search can miss e.g. Greek final sigma matches.
    query
        .chars()
        .all(|c| c.is_ascii() || matches!(c, '\u{3400}'..='\u{9fff}'))
}

struct Entry {
    path: Box<str>,
    searchable_path: Option<Box<str>>,
    display: Box<str>,
    display_len: usize,
    name: Option<Box<str>>,
    kind: Box<str>,
    availability: Box<str>,
    full: Box<str>,
    initials: Box<str>,
}

impl Entry {
    fn name(&self) -> &str {
        self.name.as_deref().unwrap_or(&self.display)
    }

    fn searchable_path(&self) -> &str {
        self.searchable_path.as_deref().unwrap_or(&self.path)
    }

    fn has_pinyin(&self, query: &str) -> bool {
        self.full.contains(query) || self.initials.contains(query)
    }

    fn hit(&self, matched_by: &str) -> Hit {
        Hit {
            path: self.path.to_string(),
            name: self.display.to_string(),
            kind: self.kind.to_string(),
            availability: self.availability.to_string(),
            matched_by: matched_by.to_owned(),
            snippet: None,
            document_stamp: None,
            score: None,
        }
    }
}

#[derive(Default)]
struct Postings(HashMap<u32, PostingList>);

#[derive(Default)]
struct PostingList {
    // Sorted entry IDs tend to be close for common grams. Keep their gaps
    // as base-128 integers so shared path segments cost about a byte per row.
    gaps: Vec<u8>,
    count: usize,
    last: u32,
}

impl PostingList {
    fn insert(&mut self, id: u32) -> usize {
        if self.count != 0 && self.last == id {
            return 0;
        }
        let before = self.gaps.capacity();
        let mut gap = id - self.last;
        while gap >= 128 {
            self.gaps.push((gap as u8) | 128);
            gap >>= 7;
        }
        self.gaps.push(gap as u8);
        self.last = id;
        self.count += 1;
        self.gaps.capacity() - before
    }

    fn ids(&self) -> impl Iterator<Item = u32> + '_ {
        let mut bytes = self.gaps.iter();
        let mut id = 0;
        std::iter::from_fn(move || {
            let mut shift = 0;
            for &byte in bytes.by_ref() {
                id += u32::from(byte & 127) << shift;
                if byte < 128 {
                    return Some(id);
                }
                shift += 7;
            }
            None
        })
    }
}

impl Postings {
    fn add(&mut self, text: &str, id: u32, bytes: &mut usize) {
        let s = text.as_bytes();
        for (i, &a) in s.iter().enumerate() {
            if a.is_ascii() {
                self.insert(u32::from(a), id, bytes);
            }
            if let Some(&b) = s.get(i + 1) {
                if (a.is_ascii() && b.is_ascii())
                    || ((0xc2..=0xdf).contains(&a) && (0x80..=0xbf).contains(&b))
                {
                    self.insert(u32::from_be_bytes([0, 1, a, b]), id, bytes);
                }
                if let Some(&c) = s.get(i + 2) {
                    self.insert(u32::from_be_bytes([1, a, b, c]), id, bytes);
                }
            }
        }
    }

    fn insert(&mut self, gram: u32, id: u32, bytes: &mut usize) {
        let postings = self.0.entry(gram).or_default();
        if postings.count == 0 {
            // Include hash table slack in the index budget.
            *bytes += 64;
        }
        *bytes += postings.insert(id);
    }

    fn candidates(&self, query: &str) -> impl Iterator<Item = u32> + '_ {
        self.rarest(query).into_iter().flat_map(PostingList::ids)
    }

    fn rarest(&self, query: &str) -> Option<&PostingList> {
        match query.as_bytes() {
            &[a] => self.0.get(&u32::from(a)),
            &[a, b] => self.0.get(&u32::from_be_bytes([0, 1, a, b])),
            longer => {
                let mut shortest: Option<&PostingList> = None;
                for gram in longer.windows(3) {
                    let n = self
                        .0
                        .get(&u32::from_be_bytes([1, gram[0], gram[1], gram[2]]))?;
                    if shortest.is_none_or(|prior| n.count < prior.count) {
                        shortest = Some(n);
                    }
                }
                shortest
            }
        }
    }
}

#[derive(Default)]
struct NameIndex {
    // Tie-break order is precomputed once per published index generation.
    entries: Vec<Entry>,
    by_name: Vec<u32>,
    names: Postings,
    pinyin: Postings,
    paths: Postings,
}

impl NameIndex {
    fn load(db: &Path, cancel: &AtomicBool) -> Result<Option<Self>> {
        let mut index = Self::default();
        let mut bytes = 0;
        {
            let conn = open_read(db)?;
            let too_large: bool = conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM item LIMIT 1 OFFSET ?1)",
                [MAX_ROWS as i64],
                |row| row.get(0),
            )?;
            if too_large || cancel.load(Ordering::Relaxed) {
                return Ok(None);
            }
            let mut stmt = conn.prepare(
                "SELECT path,display,kind,availability,name,full,initials,searchable_path
                 FROM item WHERE availability<>'unverified' LIMIT ?1",
            )?;
            let mut rows = stmt.query([MAX_ROWS as i64 + 1])?;
            while let Some(row) = rows.next()? {
                if index.entries.len() == MAX_ROWS || cancel.load(Ordering::Relaxed) {
                    return Ok(None);
                }
                let path: Box<str> = row.get(0)?;
                let display: Box<str> = row.get(1)?;
                let kind: Box<str> = row.get(2)?;
                let availability: Box<str> = row.get(3)?;
                let name: Box<str> = row.get(4)?;
                let full: Box<str> = row.get(5)?;
                let initials: Box<str> = row.get(6)?;
                let searchable_path: Box<str> = row.get(7)?;
                if [
                    path.as_ref(),
                    display.as_ref(),
                    name.as_ref(),
                    full.as_ref(),
                    initials.as_ref(),
                    searchable_path.as_ref(),
                ]
                .iter()
                .any(|text| text.contains('\0'))
                {
                    // FTS5's behavior with embedded NUL differs from instr.
                    return Ok(None);
                }
                let name = (name != display).then_some(name);
                let searchable_path = (searchable_path != path).then_some(searchable_path);
                bytes += path.len()
                    + display.len()
                    + kind.len()
                    + availability.len()
                    + name.as_ref().map_or(0, |s| s.len())
                    + searchable_path.as_ref().map_or(0, |s| s.len())
                    + full.len()
                    + initials.len();
                let before = index.entries.capacity();
                index.entries.push(Entry {
                    path,
                    searchable_path,
                    display_len: display.chars().count(),
                    display,
                    name,
                    kind,
                    availability,
                    full,
                    initials,
                });
                bytes += (index.entries.capacity() - before) * size_of::<Entry>();
                if bytes > MAX_INDEX_BYTES {
                    return Ok(None);
                }
            }
        }
        index.entries.sort_unstable_by(|a, b| {
            a.display_len
                .cmp(&b.display_len)
                .then_with(|| a.path.cmp(&b.path))
        });
        index.by_name = (0..index.entries.len() as u32).collect();
        bytes += index.by_name.capacity() * size_of::<u32>();
        index.by_name.sort_unstable_by(|&a, &b| {
            index.entries[a as usize]
                .name()
                .cmp(index.entries[b as usize].name())
                .then_with(|| a.cmp(&b))
        });
        for (id, entry) in index.entries.iter().enumerate() {
            if cancel.load(Ordering::Relaxed) {
                return Ok(None);
            }
            let id = id as u32;
            index.names.add(entry.name(), id, &mut bytes);
            index.pinyin.add(&entry.full, id, &mut bytes);
            index.pinyin.add(&entry.initials, id, &mut bytes);
            index.paths.add(entry.searchable_path(), id, &mut bytes);
            if bytes > MAX_INDEX_BYTES {
                return Ok(None);
            }
        }
        Ok(Some(index))
    }

    fn entry(&self, id: u32) -> &Entry {
        &self.entries[id as usize]
    }

    fn search(&self, query: &str, limit: usize) -> Vec<Hit> {
        let start = self
            .by_name
            .partition_point(|&id| self.entry(id).name() < query);
        let names = &self.by_name[start..];
        let exact = names.partition_point(|&id| self.entry(id).name() == query);
        let mut hits = Vec::with_capacity(limit);
        hits.extend(
            names[..exact]
                .iter()
                .take(limit)
                .map(|&id| self.entry(id).hit("name")),
        );
        if hits.len() == limit {
            return hits;
        }

        let prefixes =
            names[exact..].partition_point(|&id| self.entry(id).name().starts_with(query));
        let mut remaining_prefixes = prefixes.min(limit - hits.len());
        let mut substrings = Vec::new();
        for id in self.names.candidates(query) {
            if hits.len() == limit
                || (remaining_prefixes == 0 && substrings.len() >= limit - hits.len())
            {
                break;
            }
            let entry = self.entry(id);
            let name = entry.name();
            if name.starts_with(query) {
                if name != query {
                    hits.push(entry.hit("name"));
                    remaining_prefixes -= 1;
                }
            } else if substrings.len() < limit - hits.len() && name.contains(query) {
                substrings.push(entry);
            }
        }
        for entry in substrings.into_iter().take(limit - hits.len()) {
            hits.push(entry.hit("name"));
        }
        for id in self.pinyin.candidates(query) {
            if hits.len() == limit {
                return hits;
            }
            let entry = self.entry(id);
            if entry.has_pinyin(query) && !entry.name().contains(query) {
                hits.push(entry.hit("pinyin"));
            }
        }
        for id in self.paths.candidates(query) {
            if hits.len() == limit {
                break;
            }
            let entry = self.entry(id);
            if entry.searchable_path().contains(query)
                && !entry.name().contains(query)
                && !entry.has_pinyin(query)
            {
                hits.push(entry.hit("path"));
            }
        }
        hits
    }
}
