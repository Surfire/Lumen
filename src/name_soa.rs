//! Compact, immutable name-search snapshot. Row IDs are dense offsets into
//! columns, never SQLite row IDs. Only the winning rows allocate hit paths.
use crate::{
    Hit, Result, open_read, pinyin,
    query::{Kind, Terms},
};
use std::{
    borrow::Cow,
    cmp::{Ordering, Reverse},
    collections::{BinaryHeap, HashMap},
    mem::size_of,
    path::Path,
    sync::atomic::{AtomicBool, Ordering::Relaxed},
};

pub(super) const MAX_INDEX_BYTES: usize = 120 * 1024 * 1024;
const DIRECTORY: u8 = 1;
const PACKAGE: u8 = 2;
const USER_AREA: u8 = 4;
const NOISE: u8 = 8;
const LOCAL: u8 = 0;
const PROVIDER: u8 = 16;
const PLACEHOLDER: u8 = 32;

#[derive(Default)]
struct Pool {
    bytes: String,
    ends: Vec<u32>,
}

impl Pool {
    fn push(&mut self, pieces: &[&str]) {
        let additional = pieces.iter().map(|s| s.len()).sum::<usize>();
        if self.bytes.len() + additional > self.bytes.capacity() {
            self.bytes.reserve_exact(additional.max(64 * 1024));
        }
        for piece in pieces {
            self.bytes.push_str(piece);
        }
        push(&mut self.ends, self.bytes.len() as u32);
    }

    fn get(&self, id: usize) -> &str {
        let start = if id == 0 {
            0
        } else {
            self.ends[id - 1] as usize
        };
        &self.bytes[start..self.ends[id] as usize]
    }

    fn capacity_bytes(&self) -> usize {
        self.bytes.capacity() + capacity_bytes(&self.ends)
    }
}

fn push<T>(column: &mut Vec<T>, value: T) {
    if column.len() == column.capacity() {
        column.reserve_exact(16 * 1024);
    }
    column.push(value);
}

fn capacity_bytes<T>(column: &Vec<T>) -> usize {
    column.capacity() * size_of::<T>()
}

#[derive(Default)]
struct PostingList {
    // Dense IDs are encoded as base-128 gaps. Each row appears once per gram.
    gaps: Vec<u8>,
    count: u32,
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

    fn ids(&self) -> impl Iterator<Item = usize> + '_ {
        let mut bytes = self.gaps.iter();
        let mut id = 0;
        std::iter::from_fn(move || {
            let mut shift = 0;
            for &byte in bytes.by_ref() {
                id += usize::from(byte & 127) << shift;
                if byte < 128 {
                    return Some(id);
                }
                shift += 7;
            }
            None
        })
    }
}

// NFKC and lowercase leave Greek final sigma distinct; FTS5 folds it to σ.
// Fold the postings without changing the stored spellings used for ranking.
fn fold_sigma(text: &str) -> Cow<'_, str> {
    if text.contains('ς') {
        Cow::Owned(text.replace('ς', "σ"))
    } else {
        Cow::Borrowed(text)
    }
}

#[derive(Default)]
struct Postings(HashMap<[u8; 3], PostingList>);

impl Postings {
    fn add(&mut self, text: &str, id: usize, budget: &mut usize) {
        for gram in fold_sigma(text).as_bytes().windows(3) {
            let list = self.0.entry(gram.try_into().unwrap()).or_default();
            if list.count == 0 {
                // Approximate hash table bucket and allocator slack.
                *budget += 64;
            }
            *budget += list.insert(id as u32);
        }
    }

    fn rarest(&self, query: &str) -> Option<&PostingList> {
        let mut shortest: Option<&PostingList> = None;
        for gram in fold_sigma(query).as_bytes().windows(3) {
            let list = self.0.get(<&[u8; 3]>::try_from(gram).unwrap())?;
            if shortest.is_none_or(|prior| list.count < prior.count) {
                shortest = Some(list);
            }
        }
        shortest
    }
}

struct Parent {
    path: Box<str>,
    folded: Option<Box<str>>,
    flags: u8,
    rows: PostingList,
}

impl Parent {
    fn folded(&self) -> &str {
        self.folded.as_deref().unwrap_or(&self.path)
    }
}

#[derive(Default)]
pub(super) struct NameIndex {
    names: Pool,
    // Sparse data in a byte pool: original display (when it differs), full
    // pinyin, initials. Rows without any of these have an empty slice.
    extras: Pool,
    parent_ids: Vec<u32>,
    flags: Vec<u8>,
    kinds: Vec<Kind>,
    mtime: Vec<u32>,
    parents: Vec<Parent>,
    words: Postings,
    paths: Postings,
    variable_bytes: usize,
}

struct Word<'a> {
    text: &'a str,
    legacy: Option<pinyin::LegacyReading>,
    fts_text: Option<Cow<'a, str>>,
}

impl Word<'_> {
    fn matches_fts(&self, value: &str) -> bool {
        self.fts_text
            .as_deref()
            .is_some_and(|text| fold_sigma(value).contains(text))
    }

    fn matches_path(&self, parent: &str, name: &str) -> bool {
        contains_path(parent, name, self.text)
            || self
                .fts_text
                .as_deref()
                .is_some_and(|text| contains_path(&fold_sigma(parent), &fold_sigma(name), text))
    }
}

struct Seed<'a> {
    word: usize,
    names: Option<&'a PostingList>,
    alias: Option<&'a PostingList>,
    parents: Vec<usize>,
    count: usize,
}

// Worst tier and total tier come first, keeping match quality ahead of
// cleanliness, recency, and kind. Width and lexical path stabilize ties.
#[derive(Eq, PartialEq)]
struct Ranked<'a> {
    score: (u8, u16, bool, Reverse<u32>, u8, usize),
    parent: &'a str,
    display: &'a str,
    id: usize,
}

impl Ord for Ranked<'_> {
    fn cmp(&self, other: &Self) -> Ordering {
        self.score
            .cmp(&other.score)
            .then_with(|| {
                if self.parent == other.parent {
                    self.display.cmp(other.display)
                } else {
                    self.parent
                        .bytes()
                        .chain(self.display.bytes())
                        .cmp(other.parent.bytes().chain(other.display.bytes()))
                }
            })
            .then_with(|| self.id.cmp(&other.id))
    }
}

impl PartialOrd for Ranked<'_> {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl NameIndex {
    pub(super) fn load(db: &Path, cancel: &AtomicBool, budget: usize) -> Result<Option<Self>> {
        let home = std::env::var_os("HOME").and_then(|home| crate::absolute(Path::new(&home)).ok());
        let conn = open_read(db)?;
        let mut index = Self::default();
        let mut intern = HashMap::<Box<str>, u32>::new();
        let mut intern_bytes = 0;
        let mtime = if super::has_mtime(&conn)? {
            "mtime"
        } else {
            "0"
        };
        let mut stmt = conn.prepare(&format!(
            "SELECT path,display,kind,availability,name,full,initials,searchable_path,{mtime}
             FROM item WHERE availability<>'unverified' ORDER BY id"
        ))?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            if cancel.load(Relaxed) {
                return Ok(None);
            }
            let path = row.get_ref(0)?.as_str()?;
            let display = row.get_ref(1)?.as_str()?;
            let directory = row.get_ref(2)?.as_str()? == "directory";
            let availability = match row.get_ref(3)?.as_str()? {
                "local" => LOCAL,
                "provider_metadata_only" => PROVIDER,
                "placeholder" => PLACEHOLDER,
                _ => return Ok(None),
            };
            let name = row.get_ref(4)?.as_str()?;
            let full = row.get_ref(5)?.as_str()?;
            let initials = row.get_ref(6)?.as_str()?;
            let folded = row.get_ref(7)?.as_str()?;
            let mtime: i64 = row.get(8)?;
            // In a Lumen catalog the two spellings share a parent boundary.
            // Fall back for unfamiliar rows instead of changing their paths.
            let (Some(parent), Some(folded_parent)) =
                (path.strip_suffix(display), folded.strip_suffix(name))
            else {
                return Ok(None);
            };
            if [path, display, name, full, initials, folded]
                .iter()
                .any(|s| s.contains('\0'))
            {
                return Ok(None);
            }
            let parent_id = if let Some(&parent_id) = intern.get(parent) {
                if index.parents[parent_id as usize].folded() != folded_parent {
                    return Ok(None);
                }
                parent_id
            } else {
                let parent_path = Path::new(parent);
                let flags = if home
                    .as_ref()
                    .is_some_and(|home| parent_path.starts_with(home))
                {
                    USER_AREA
                } else {
                    0
                } | if crate::development_noise(parent_path, &[])
                    || crate::sensitive_path(parent_path)
                    || crate::system_path(parent_path)
                {
                    NOISE
                } else {
                    0
                };
                let id = index.parents.len();
                index
                    .paths
                    .add(folded_parent, id, &mut index.variable_bytes);
                index.variable_bytes += parent.len()
                    + if folded_parent != parent {
                        folded_parent.len()
                    } else {
                        0
                    };
                index.parents.push(Parent {
                    path: parent.into(),
                    folded: (folded_parent != parent).then(|| folded_parent.into()),
                    flags,
                    rows: PostingList::default(),
                });
                intern_bytes += parent.len() + 32;
                intern.insert(parent.into(), id as u32);
                id as u32
            };
            let id = index.flags.len();
            let parent = &mut index.parents[parent_id as usize];
            index.variable_bytes += parent.rows.insert(id as u32);
            let mut flags = parent.flags | availability;
            if directory {
                flags |= DIRECTORY;
                if crate::index::opaque_package(Path::new(display)) {
                    flags |= PACKAGE;
                }
            }
            if flags & USER_AREA != 0
                && (crate::development_noise(Path::new(display), &[])
                    || crate::sensitive_path(Path::new(display)))
            {
                flags |= NOISE;
            }
            index.names.push(&[name]);
            if name == display && full.is_empty() && initials.is_empty() {
                index.extras.push(&[]);
            } else {
                index.extras.push(&[
                    if name != display { display } else { "" },
                    "\0",
                    full,
                    "\0",
                    initials,
                ]);
            }
            push(&mut index.parent_ids, parent_id);
            push(&mut index.flags, flags);
            push(&mut index.kinds, Kind::classify(name, directory));
            push(&mut index.mtime, mtime.clamp(0, i64::from(u32::MAX)) as u32);
            index.words.add(name, id, &mut index.variable_bytes);
            index.words.add(full, id, &mut index.variable_bytes);
            index.words.add(initials, id, &mut index.variable_bytes);
            if index.capacity_bytes() + intern_bytes > budget {
                return Ok(None);
            }
        }
        Ok(Some(index))
    }

    pub(super) fn capacity_bytes(&self) -> usize {
        self.variable_bytes
            + self.names.capacity_bytes()
            + self.extras.capacity_bytes()
            + capacity_bytes(&self.parent_ids)
            + capacity_bytes(&self.flags)
            + capacity_bytes(&self.kinds)
            + capacity_bytes(&self.mtime)
            + capacity_bytes(&self.parents)
    }

    fn extras(&self, id: usize) -> (&str, &str, &str) {
        let value = self.extras.get(id);
        if value.is_empty() {
            return ("", "", "");
        }
        let (display, keys) = value.split_once('\0').unwrap();
        let (full, initials) = keys.split_once('\0').unwrap();
        (display, full, initials)
    }

    fn name_tier(&self, id: usize, word: &Word<'_>) -> Option<u8> {
        let name = self.names.get(id);
        let text = word.text;
        if name == text {
            return Some(0);
        }
        if name.starts_with(text) {
            return Some(1);
        }
        if name.contains(text) {
            return Some(2);
        }
        let (_, full, initials) = self.extras(id);
        if full.contains(text)
            || initials.contains(text)
            || word.legacy.as_ref().is_some_and(|legacy| {
                let key = if legacy.initials { initials } else { full };
                key.contains(&legacy.key)
                    && legacy.phrases.iter().all(|phrase| name.contains(phrase))
            })
        {
            return Some(3);
        }
        // The cold FTS query ranks fold-only hits in the same tier as paths.
        (word.matches_fts(name) || word.matches_fts(full) || word.matches_fts(initials))
            .then_some(4)
    }

    fn seed<'a>(&'a self, words: &[Word<'_>]) -> Option<Seed<'a>> {
        let mut best: Option<Seed<'a>> = None;
        for (i, word) in words.iter().enumerate() {
            if word.text.len() < 3
                || word.text.contains('/')
                || word
                    .legacy
                    .as_ref()
                    .is_some_and(|legacy| legacy.key.len() < 3)
            {
                continue;
            }
            let names = self.words.rarest(word.text);
            let alias = word
                .legacy
                .as_ref()
                .and_then(|legacy| self.words.rarest(&legacy.key));
            let mut count = names.map_or(0, |list| list.count as usize)
                + alias.map_or(0, |list| list.count as usize);
            let mut parents = Vec::new();
            if let Some(list) = self.paths.rarest(word.text) {
                for id in list.ids() {
                    let parent = &self.parents[id];
                    if parent.folded().contains(word.text) || word.matches_fts(parent.folded()) {
                        parents.push(id);
                        count += parent.rows.count as usize;
                    }
                }
            }
            if best.as_ref().is_none_or(|seed| count < seed.count) {
                best = Some(Seed {
                    word: i,
                    names,
                    alias,
                    parents,
                    count,
                });
                if count == 0 {
                    break;
                }
            }
        }
        best
    }

    pub(super) fn search(&self, query: &str, terms: Option<&Terms>, limit: usize) -> Vec<Hit> {
        if terms.is_some_and(|t| t.conflicting || t.is_empty()) {
            return Vec::new();
        }
        let words = terms.map_or_else(
            || vec![query],
            |t| t.words.iter().map(String::as_str).collect(),
        );
        let words: Vec<_> = words
            .into_iter()
            .map(|text| Word {
                text,
                legacy: pinyin::legacy(text),
                // Only an unstructured trigram query accepts fold-only hits.
                fts_text: (terms.is_none()
                    && text.contains(['σ', 'ς'])
                    && text.chars().count() >= 3)
                    .then(|| fold_sigma(text)),
            })
            .collect();
        let mut heap = BinaryHeap::<Ranked<'_>>::with_capacity(limit);
        let mut consider = |id, seed_tier: Option<(usize, u8)>| {
            let flags = self.flags[id];
            let kind = self.kinds[id];
            let name = self.names.get(id);
            let parent = &self.parents[self.parent_ids[id] as usize];
            if terms.is_some_and(|t| {
                t.kind.is_some_and(|wanted| wanted != kind)
                    || t.suffix.as_ref().is_some_and(|suffix| {
                        flags & DIRECTORY != 0
                            || name.len() <= suffix.len()
                            || !name.ends_with(suffix)
                    })
                    || !t
                        .paths
                        .iter()
                        .all(|path| matches_prefix(parent.folded(), name, path))
            }) {
                return;
            }
            let mut worst = 0;
            let mut sum = 0;
            for (i, word) in words.iter().enumerate() {
                let tier = if let Some((seed, tier)) = seed_tier
                    && seed == i
                {
                    tier
                } else if let Some(tier) = self.name_tier(id, word) {
                    tier
                } else if word.matches_path(parent.folded(), name) {
                    4
                } else {
                    return;
                };
                worst = worst.max(tier);
                sum += u16::from(tier);
            }
            let prefix = (
                worst,
                sum,
                flags & (USER_AREA | NOISE) != USER_AREA,
                Reverse(self.mtime[id]),
                match kind {
                    Kind::App => 0,
                    Kind::Doc => 1,
                    Kind::Folder if flags & PACKAGE == 0 => 1,
                    Kind::Folder => Kind::Other as u8,
                    _ => kind as u8,
                },
            );
            if heap.peek().is_some_and(|top| {
                heap.len() == limit
                    && prefix
                        > (
                            top.score.0,
                            top.score.1,
                            top.score.2,
                            top.score.3,
                            top.score.4,
                        )
            }) {
                return;
            }
            let (display, _, _) = self.extras(id);
            let display = if display.is_empty() { name } else { display };
            let ranked = Ranked {
                score: (
                    prefix.0,
                    prefix.1,
                    prefix.2,
                    prefix.3,
                    prefix.4,
                    display.chars().count(),
                ),
                parent: &parent.path,
                display,
                id,
            };
            if heap.len() < limit {
                heap.push(ranked);
            } else if let Some(mut top) = heap.peek_mut()
                && ranked < *top
            {
                *top = ranked;
            }
        };
        if let Some(seed) = self.seed(&words) {
            let word = &words[seed.word];
            let mut names = seed.names.into_iter().flat_map(PostingList::ids).peekable();
            let mut aliases = seed.alias.into_iter().flat_map(PostingList::ids).peekable();
            while let Some(id) = match (names.peek().copied(), aliases.peek().copied()) {
                (Some(a), Some(b)) if a == b => {
                    aliases.next();
                    names.next()
                }
                (Some(a), Some(b)) if a < b => names.next(),
                (Some(_), Some(_)) | (None, Some(_)) => aliases.next(),
                _ => names.next(),
            } {
                if let Some(tier) = self.name_tier(id, word) {
                    consider(id, Some((seed.word, tier)));
                }
            }
            for parent in seed.parents {
                for id in self.parents[parent].rows.ids() {
                    if self.name_tier(id, word).is_none() {
                        consider(id, Some((seed.word, 4)));
                    }
                }
            }
        } else {
            for id in 0..self.flags.len() {
                consider(id, None);
            }
        }
        heap.into_sorted_vec()
            .into_iter()
            .map(|row| {
                let flags = self.flags[row.id];
                let path = [row.parent, row.display].concat();
                Hit {
                    path,
                    name: row.display.to_owned(),
                    kind: if flags & DIRECTORY != 0 {
                        "directory"
                    } else {
                        "file"
                    }
                    .to_owned(),
                    availability: match flags & (PROVIDER | PLACEHOLDER) {
                        PROVIDER => "provider_metadata_only",
                        PLACEHOLDER => "placeholder",
                        _ => "local",
                    }
                    .to_owned(),
                    matched_by: match row.score.0 {
                        4 => "path",
                        3 => "pinyin",
                        _ => "name",
                    }
                    .to_owned(),
                    snippet: None,
                    document_stamp: None,
                    pdf_page: None,
                    score: None,
                }
            })
            .collect()
    }
}

fn matches_prefix(parent: &str, name: &str, prefix: &str) -> bool {
    if let Some(rest) = prefix.strip_prefix(parent) {
        name.strip_prefix(rest)
            .is_some_and(|tail| tail.is_empty() || prefix.ends_with('/') || tail.starts_with('/'))
    } else {
        parent
            .strip_prefix(prefix)
            .is_some_and(|tail| prefix.ends_with('/') || tail.starts_with('/'))
    }
}

fn contains_path(parent: &str, name: &str, word: &str) -> bool {
    parent.contains(word)
        || word
            .match_indices('/')
            .any(|(i, _)| parent.ends_with(&word[..=i]) && name.starts_with(&word[i + 1..]))
}
