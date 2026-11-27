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

pub(super) const MAX_INDEX_BYTES: usize = 256 * 1024 * 1024;
const DIRECTORY: u8 = 1;
const PACKAGE: u8 = 2;
const USER_AREA: u8 = 4;
const NOISE: u8 = 8;
const LOCAL: u8 = 0;
const PROVIDER: u8 = 16;
const PLACEHOLDER: u8 = 32;
const HAS_EXTRA: u8 = 64;

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

    fn range(&self, id: usize) -> (usize, usize) {
        let start = if id == 0 {
            0
        } else {
            self.ends[id - 1] as usize
        };
        (start, self.ends[id] as usize)
    }

    fn get(&self, id: usize) -> &str {
        let (start, end) = self.range(id);
        &self.bytes[start..end]
    }

    fn capacity_bytes(&self) -> usize {
        self.bytes.capacity() + capacity_bytes(&self.ends)
    }

    fn shrink_to_fit(&mut self) {
        self.bytes.shrink_to_fit();
        self.ends.shrink_to_fit();
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

// NFKC and lowercase leave Greek final sigma distinct; FTS5 folds it to σ.
// Fold only when needed without changing stored spellings used for ranking.
fn fold_sigma(text: &str) -> Cow<'_, str> {
    if text.contains('ς') {
        Cow::Owned(text.replace('ς', "σ"))
    } else {
        Cow::Borrowed(text)
    }
}

#[cfg(target_arch = "aarch64")]
#[inline]
fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    use std::arch::aarch64::*;

    let nlen = needle.len();
    if nlen == 0 {
        return Some(0);
    }
    if nlen > haystack.len() {
        return None;
    }
    let last = haystack.len() - nlen;
    let first_byte = needle[0];
    let tail_byte = needle[nlen - 1];
    let ptr = haystack.as_ptr();
    let mut i = 0;

    if i + nlen + 15 <= haystack.len() {
        unsafe {
            let first = vdupq_n_u8(first_byte);
            let tail = vdupq_n_u8(tail_byte);
            while i + nlen + 15 <= haystack.len() {
                let a = vld1q_u8(ptr.add(i));
                let b = if nlen == 1 {
                    a
                } else {
                    vld1q_u8(ptr.add(i + nlen - 1))
                };
                let matched = vandq_u8(vceqq_u8(a, first), vceqq_u8(b, tail));
                let nibbles = vshrn_n_u16::<4>(vreinterpretq_u16_u8(matched));
                let mut mask = vget_lane_u64::<0>(vreinterpret_u64_u8(nibbles));
                while mask != 0 {
                    let bit = mask.trailing_zeros() as usize;
                    let p = i + (bit >> 2);
                    if nlen <= 2 || haystack[p + 1..p + nlen - 1] == needle[1..nlen - 1] {
                        return Some(p);
                    }
                    mask &= !(0xF_u64 << (bit & !3));
                }
                i += 16;
            }
        }
    }

    while i <= last {
        if haystack[i] == first_byte
            && haystack[i + nlen - 1] == tail_byte
            && (nlen <= 2 || haystack[i + 1..i + nlen - 1] == needle[1..nlen - 1])
        {
            return Some(i);
        }
        i += 1;
    }
    None
}

#[cfg(not(target_arch = "aarch64"))]
#[inline]
fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        return Some(0);
    }
    haystack.windows(needle.len()).position(|w| w == needle)
}

#[inline]
fn scan_pool_chunk(
    pool: &Pool,
    row_start: usize,
    row_end: usize,
    needle: &[u8],
    mut on_hit: impl FnMut(usize),
) {
    if row_start >= row_end || needle.is_empty() {
        return;
    }
    let slice = pool.bytes.as_bytes();
    let end_pos = pool.ends[row_end - 1] as usize;
    let mut row = row_start;
    let mut pos = if row_start == 0 {
        0
    } else {
        pool.ends[row_start - 1] as usize
    };
    while row < row_end && pos + needle.len() <= end_pos {
        let Some(rel) = find_bytes(&slice[pos..end_pos], needle) else {
            break;
        };
        let hit = pos + rel;
        while pool.ends[row] as usize <= hit {
            row += 1;
        }
        let row_end_byte = pool.ends[row] as usize;
        if hit + needle.len() <= row_end_byte {
            on_hit(row);
        }
        // Any later hit inside row < row_end_byte either belongs to the same matched row
        // or exceeds row_end_byte, so jumping to row + 1 preserves every valid match.
        row += 1;
        pos = row_end_byte;
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
    parent_paths: Pool,
    parent_folded: Pool,
    parent_flags: Vec<u8>,
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
            .is_some_and(|text| find_bytes(fold_sigma(value).as_bytes(), text.as_bytes()).is_some())
    }

    fn matches_path(&self, parent: &str, name: &str) -> bool {
        contains_path(parent, name, self.text)
            || self
                .fts_text
                .as_deref()
                .is_some_and(|text| contains_path(&fold_sigma(parent), &fold_sigma(name), text))
    }
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
    fn parent_folded_str(&self, parent_id: usize) -> &str {
        let (start, end) = self.parent_folded.range(parent_id);
        if end > start {
            &self.parent_folded.bytes[start..end]
        } else {
            self.parent_paths.get(parent_id)
        }
    }

    pub(super) fn load(
        db: &Path,
        cancel: &AtomicBool,
        budget: usize,
    ) -> Result<Option<(i64, Self)>> {
        let home = std::env::var_os("HOME").and_then(|home| crate::absolute(Path::new(&home)).ok());
        let conn = open_read(db)?;
        let tx = conn.unchecked_transaction()?;
        let Some(generation) = super::name_generation(&tx)? else {
            return Ok(None);
        };
        #[cfg(test)]
        super::maybe_pause_load_for_test(db);
        let mut index = Self::default();
        let mut intern = HashMap::<Box<str>, u32>::new();
        let mtime = if super::has_mtime(&tx)? { "mtime" } else { "0" };
        let mut stmt = tx.prepare(&format!(
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
                if index.parent_folded_str(parent_id as usize) != folded_parent {
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
                let id = index.parent_flags.len();
                index.parent_paths.push(&[parent]);
                if folded_parent != parent {
                    index.parent_folded.push(&[folded_parent]);
                } else {
                    index.parent_folded.push(&[]);
                }
                push(&mut index.parent_flags, flags);
                intern.insert(parent.into(), id as u32);
                id as u32
            };
            let pflags = index.parent_flags[parent_id as usize];
            let mut flags = pflags | availability;
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
                flags |= HAS_EXTRA;
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
            if index.capacity_bytes() > budget {
                return Ok(None);
            }
        }
        drop(intern);
        index.names.shrink_to_fit();
        index.extras.shrink_to_fit();
        index.parent_ids.shrink_to_fit();
        index.flags.shrink_to_fit();
        index.kinds.shrink_to_fit();
        index.mtime.shrink_to_fit();
        index.parent_paths.shrink_to_fit();
        index.parent_folded.shrink_to_fit();
        index.parent_flags.shrink_to_fit();
        Ok(Some((generation, index)))
    }

    pub(super) fn capacity_bytes(&self) -> usize {
        self.names.capacity_bytes()
            + self.extras.capacity_bytes()
            + capacity_bytes(&self.parent_ids)
            + capacity_bytes(&self.flags)
            + capacity_bytes(&self.kinds)
            + capacity_bytes(&self.mtime)
            + self.parent_paths.capacity_bytes()
            + self.parent_folded.capacity_bytes()
            + capacity_bytes(&self.parent_flags)
    }

    fn extras(&self, id: usize) -> (&str, &str, &str) {
        if self.flags[id] & HAS_EXTRA == 0 {
            return ("", "", "");
        }
        let value = self.extras.get(id);
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
        if find_bytes(name.as_bytes(), text.as_bytes()).is_some() {
            return Some(2);
        }
        if self.flags[id] & HAS_EXTRA != 0 {
            let (_, full, initials) = self.extras(id);
            let tbytes = text.as_bytes();
            if find_bytes(full.as_bytes(), tbytes).is_some()
                || find_bytes(initials.as_bytes(), tbytes).is_some()
                || word.legacy.as_ref().is_some_and(|legacy| {
                    let key = if legacy.initials { initials } else { full };
                    find_bytes(key.as_bytes(), legacy.key.as_bytes()).is_some()
                        && legacy
                            .phrases
                            .iter()
                            .all(|phrase| find_bytes(name.as_bytes(), phrase.as_bytes()).is_some())
                })
            {
                return Some(3);
            }
            if word.matches_fts(name) || word.matches_fts(full) || word.matches_fts(initials) {
                return Some(4);
            }
            return None;
        }
        word.matches_fts(name).then_some(4)
    }

    fn finish_hits(heap: BinaryHeap<Ranked<'_>>, flags_col: &[u8]) -> Vec<Hit> {
        heap.into_sorted_vec()
            .into_iter()
            .map(|row| {
                let flags = flags_col[row.id];
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

    fn consider<'a>(
        &'a self,
        heap: &mut BinaryHeap<Ranked<'a>>,
        ctx: &QueryContext<'_, '_>,
        id: usize,
        seed_tier: Option<(usize, u8)>,
    ) {
        let flags = self.flags[id];
        let kind = self.kinds[id];
        let name = self.names.get(id);
        let parent_id = self.parent_ids[id] as usize;
        let parent_folded = self.parent_folded_str(parent_id);
        if let Some(t) = ctx.terms {
            if t.kind.is_some_and(|wanted| wanted != kind)
                || t.suffix.as_ref().is_some_and(|suffix| {
                    flags & DIRECTORY != 0 || name.len() <= suffix.len() || !name.ends_with(suffix)
                })
            {
                return;
            }
            if let Some(states) = ctx.path_state {
                match states[parent_id] {
                    0 => return,
                    1 if !t
                        .paths
                        .iter()
                        .all(|path| matches_prefix(parent_folded, name, path)) =>
                    {
                        return;
                    }
                    _ => {}
                }
            }
        }
        let mut worst = 0;
        let mut sum = 0;
        for (i, word) in ctx.words.iter().enumerate() {
            let tier = if let Some((seed, tier)) = seed_tier
                && seed == i
            {
                tier
            } else if let Some(tier) = self.name_tier(id, word) {
                tier
            } else if word.matches_path(parent_folded, name) {
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
            heap.len() == ctx.limit
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
            parent: self.parent_paths.get(parent_id),
            display,
            id,
        };
        if heap.len() < ctx.limit {
            heap.push(ranked);
        } else if let Some(mut top) = heap.peek_mut()
            && ranked < *top
        {
            *top = ranked;
        }
    }

    pub(super) fn search(&self, query: &str, terms: Option<&Terms>, limit: usize) -> Vec<Hit> {
        if terms.is_some_and(|t| t.conflicting || t.is_empty()) || self.flags.is_empty() {
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
        let num_parents = self.parent_flags.len();
        let path_state: Option<Vec<u8>> = terms.and_then(|t| {
            (!t.paths.is_empty()).then(|| {
                (0..num_parents)
                    .map(|p| {
                        let parent = self.parent_folded_str(p);
                        if t.paths
                            .iter()
                            .all(|prefix| prefix.strip_prefix(parent).is_none())
                        {
                            // Neither prefix starts with parent -> check parent-only condition once.
                            if t.paths.iter().all(|prefix| {
                                parent.strip_prefix(prefix.as_str()).is_some_and(|tail| {
                                    prefix.ends_with('/') || tail.starts_with('/')
                                })
                            }) {
                                2
                            } else {
                                0
                            }
                        } else {
                            1
                        }
                    })
                    .collect()
            })
        });
        let primary_idx = words
            .iter()
            .enumerate()
            .filter(|(_, w)| !w.text.is_empty() && !w.text.contains('/') && w.fts_text.is_none())
            .max_by_key(|(_, w)| (w.text.len(), usize::from(w.legacy.is_none())))
            .map(|(i, _)| i);

        let n = self.flags.len();
        let workers = if n >= 65_536 {
            std::thread::available_parallelism()
                .map_or(1, |p| p.get())
                .min(6)
        } else {
            1
        };
        let ctx = QueryContext {
            words: &words,
            terms,
            path_state: path_state.as_deref(),
            limit,
        };

        let mut merged = BinaryHeap::<Ranked<'_>>::with_capacity(limit);
        if let Some(p_idx) = primary_idx {
            let primary = &words[p_idx];
            let needle = primary.text.as_bytes();
            run_chunks(workers, n, limit, &mut merged, |start, end| {
                let mut heap = BinaryHeap::<Ranked<'_>>::with_capacity(limit);
                scan_pool_chunk(&self.names, start, end, needle, |id| {
                    let name = self.names.get(id);
                    let tier = if name == primary.text {
                        0
                    } else if name.starts_with(primary.text) {
                        1
                    } else {
                        2
                    };
                    self.consider(&mut heap, &ctx, id, Some((p_idx, tier)));
                });
                scan_pool_chunk(&self.extras, start, end, needle, |id| {
                    if self.flags[id] & HAS_EXTRA == 0
                        || find_bytes(self.names.get(id).as_bytes(), needle).is_some()
                    {
                        return;
                    }
                    self.consider(&mut heap, &ctx, id, None);
                });
                if let Some(legacy) = &primary.legacy {
                    let legacy_bytes = legacy.key.as_bytes();
                    scan_pool_chunk(&self.extras, start, end, legacy_bytes, |id| {
                        if self.flags[id] & HAS_EXTRA == 0
                            || find_bytes(self.names.get(id).as_bytes(), needle).is_some()
                            || find_bytes(self.extras.get(id).as_bytes(), needle).is_some()
                        {
                            return;
                        }
                        self.consider(&mut heap, &ctx, id, None);
                    });
                }
                heap
            });

            // Tier-4 parent-path fallback only needed if fewer than `limit` non-path matches were found.
            if !(merged.len() == limit && merged.peek().is_some_and(|top| top.score.0 < 4)) {
                let parent_word_hit: Vec<bool> = (0..num_parents)
                    .map(|p| find_bytes(self.parent_folded_str(p).as_bytes(), needle).is_some())
                    .collect();
                let parent_hits = &parent_word_hit;
                run_chunks(workers, n, limit, &mut merged, |start, end| {
                    let mut heap = BinaryHeap::<Ranked<'_>>::with_capacity(limit);
                    for id in start..end {
                        if parent_hits[self.parent_ids[id] as usize]
                            && self.name_tier(id, primary).is_none()
                        {
                            self.consider(&mut heap, &ctx, id, Some((p_idx, 4)));
                        }
                    }
                    heap
                });
            }
        } else {
            run_chunks(workers, n, limit, &mut merged, |start, end| {
                let mut heap = BinaryHeap::<Ranked<'_>>::with_capacity(limit);
                for id in start..end {
                    self.consider(&mut heap, &ctx, id, None);
                }
                heap
            });
        }
        Self::finish_hits(merged, &self.flags)
    }
}

struct QueryContext<'a, 'q> {
    words: &'a [Word<'q>],
    terms: Option<&'a Terms>,
    path_state: Option<&'a [u8]>,
    limit: usize,
}

fn merge_heap<'a>(dst: &mut BinaryHeap<Ranked<'a>>, src: BinaryHeap<Ranked<'a>>, limit: usize) {
    for item in src {
        if dst.len() < limit {
            dst.push(item);
        } else if let Some(mut top) = dst.peek_mut()
            && item < *top
        {
            *top = item;
        }
    }
}

fn run_chunks<'a>(
    workers: usize,
    n: usize,
    limit: usize,
    merged: &mut BinaryHeap<Ranked<'a>>,
    work: impl Fn(usize, usize) -> BinaryHeap<Ranked<'a>> + Sync,
) {
    if workers <= 1 {
        merge_heap(merged, work(0, n), limit);
        return;
    }
    let chunk_size = n.div_ceil(workers);
    std::thread::scope(|scope| {
        let mut handles = Vec::with_capacity(workers);
        for w in 0..workers {
            let start = w * chunk_size;
            let end = ((w + 1) * chunk_size).min(n);
            if start < end {
                let work = &work;
                handles.push(scope.spawn(move || work(start, end)));
            }
        }
        for handle in handles {
            merge_heap(merged, handle.join().unwrap(), limit);
        }
    });
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn search_full_scan(
        index: &NameIndex,
        query: &str,
        terms: Option<&Terms>,
        limit: usize,
    ) -> Vec<Hit> {
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
                fts_text: (terms.is_none()
                    && text.contains(['σ', 'ς'])
                    && text.chars().count() >= 3)
                    .then(|| fold_sigma(text)),
            })
            .collect();
        let mut heap = BinaryHeap::<Ranked<'_>>::with_capacity(limit);
        for id in 0..index.flags.len() {
            let flags = index.flags[id];
            let kind = index.kinds[id];
            let name = index.names.get(id);
            let parent_id = index.parent_ids[id] as usize;
            let parent_folded = index.parent_folded_str(parent_id);
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
                        .all(|path| matches_prefix(parent_folded, name, path))
            }) {
                continue;
            }
            let mut worst = 0;
            let mut sum = 0;
            let mut matched = true;
            for word in &words {
                let Some(tier) = index
                    .name_tier(id, word)
                    .or_else(|| word.matches_path(parent_folded, name).then_some(4))
                else {
                    matched = false;
                    break;
                };
                worst = worst.max(tier);
                sum += u16::from(tier);
            }
            if !matched {
                continue;
            }
            let (display, _, _) = index.extras(id);
            let display = if display.is_empty() { name } else { display };
            let ranked = Ranked {
                score: (
                    worst,
                    sum,
                    flags & (USER_AREA | NOISE) != USER_AREA,
                    Reverse(index.mtime[id]),
                    match kind {
                        Kind::App => 0,
                        Kind::Doc => 1,
                        Kind::Folder if flags & PACKAGE == 0 => 1,
                        Kind::Folder => Kind::Other as u8,
                        _ => kind as u8,
                    },
                    display.chars().count(),
                ),
                parent: index.parent_paths.get(parent_id),
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
        }
        NameIndex::finish_hits(heap, &index.flags)
    }

    #[test]
    fn short_one_and_two_char_queries_match_full_scan_for_ascii_utf8_and_han() {
        let dir = std::fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-soa-short-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("index.sqlite");
        let (writer, _) = crate::open_write(&db, false).unwrap();
        let home = crate::absolute(Path::new(&std::env::var_os("HOME").unwrap())).unwrap();
        let rows = [
            (home.join("Desktop/s"), "file", "", "", 10),
            (home.join("Desktop/sample.txt"), "file", "", "", 50),
            (home.join("Desktop/notes.txt"), "file", "", "", 40),
            (home.join("Desktop/ab"), "directory", "", "", 20),
            (home.join("Desktop/ab-draft.pdf"), "file", "", "", 80),
            (home.join("Desktop/cab.md"), "file", "", "", 70),
            (home.join("Desktop/ab/deep.txt"), "file", "", "", 90),
            (
                home.join("Desktop/微信.app"),
                "directory",
                "weixin",
                "wx",
                100,
            ),
            (
                home.join("Desktop/测试微信记录.md"),
                "file",
                "ceshiweixinjilu",
                "cswxjl",
                60,
            ),
            (home.join("Desktop/微光.png"), "file", "weiguang", "wg", 55),
            (home.join("Desktop/微信/chat.txt"), "file", "", "", 30),
            (home.join("Desktop/élan.txt"), "file", "", "", 25),
            (home.join("Desktop/café.md"), "file", "", "", 35),
            (home.join("Desktop/α-notes.txt"), "file", "", "", 45),
            (
                home.join("Desktop/厦门指南.pdf"),
                "file",
                "shamen",
                "sm",
                65,
            ),
            (PathBuf::from("/alpha/zx/leaf.txt"), "file", "", "", 95),
            (PathBuf::from("/a/anchor.txt"), "file", "", "", 15),
        ];
        for (path, kind, full, initials, mtime) in rows {
            let path_str = path.to_str().unwrap();
            let display = path.file_name().unwrap().to_str().unwrap();
            writer
                .execute(
                    "INSERT INTO item VALUES(NULL,?1,?2,?3,'local',?4,?5,?6,?7,?8)",
                    rusqlite::params![
                        path_str,
                        display,
                        kind,
                        crate::norm(display),
                        full,
                        initials,
                        crate::norm(path_str),
                        mtime,
                    ],
                )
                .unwrap();
        }
        drop(writer);
        let (_, index) = NameIndex::load(&db, &AtomicBool::new(false), MAX_INDEX_BYTES)
            .unwrap()
            .unwrap();
        let summarize = |hits: Vec<Hit>| {
            hits.into_iter()
                .map(|h| (h.path, h.name, h.kind, h.availability, h.matched_by))
                .collect::<Vec<_>>()
        };

        for query in [
            "s",
            "a",
            "z",
            "ab",
            "zx",
            "xm",
            "é",
            "α",
            "微",
            "微信",
            "\"a/\"",
            "\"/a\"",
            "s kind:doc",
            "ab ext:pdf",
            "s a",
            "微信 a",
            "~/desktop/ s",
            "q",
        ] {
            let normalized = crate::norm(query.trim());
            let terms = Terms::parse(&normalized);
            for limit in [1, 2, 5, 20] {
                let actual = summarize(index.search(&normalized, terms.as_ref(), limit));
                let expected =
                    summarize(search_full_scan(&index, &normalized, terms.as_ref(), limit));
                assert_eq!(
                    actual, expected,
                    "mismatch for query={query:?} limit={limit}"
                );
            }
        }
        // Verify NEON/scalar byte scanner across alignment and multi-byte boundaries, plus multi-threaded SoA parity.
        assert_eq!(find_bytes(b"hello", b""), Some(0));
        assert_eq!(find_bytes(b"", b"a"), None);
        assert_eq!(find_bytes(b"a", b"a"), Some(0));
        assert_eq!(find_bytes(b"ab", b"ba"), None);
        assert_eq!(find_bytes(b"0123456789abcdefXneedle", b"X"), Some(16));
        assert_eq!(
            find_bytes(b"0123456789abcdef0123456789abcdef_needle", b"needle"),
            Some(33)
        );
        assert_eq!(find_bytes(b"0123456789abcdef_end", b"end"), Some(17));
        assert_eq!(
            find_bytes("这是中文方案文件名".as_bytes(), "方案".as_bytes()),
            Some(12)
        );
        assert_eq!(
            find_bytes(b"0123456789abcdef_almost_but_not", b"absent"),
            None
        );

        let large_db = dir.join("large.sqlite");
        let (large_writer, _) = crate::open_write(&large_db, false).unwrap();
        large_writer
            .execute_batch(
                "WITH RECURSIVE seq(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM seq WHERE n<70000)
                 INSERT INTO item SELECT n, printf('/scope/dir-%03d/file-%05d.md', n%200, n),
                 printf('file-%05d.md', n), 'file', 'local', printf('file-%05d.md', n), '', '',
                 printf('/scope/dir-%03d/file-%05d.md', n%200, n), n FROM seq;
                 INSERT INTO item VALUES(70001, '/scope/方案目录/临床研究方案.pdf', '临床研究方案.pdf',
                 'file', 'local', '临床研究方案.pdf', 'linchuangyanjiufanganpdf', 'lcyjfapdf',
                 '/scope/方案目录/临床研究方案.pdf', 999999);
                 INSERT INTO item VALUES(70002, '/scope/scheme/report.docx', 'report.docx',
                 'file', 'local', 'report.docx', '', '', '/scope/scheme/report.docx', 888888);",
            )
            .unwrap();
        drop(large_writer);
        let (_, large_index) = NameIndex::load(&large_db, &AtomicBool::new(false), MAX_INDEX_BYTES)
            .unwrap()
            .unwrap();
        for q in [
            "file-69999",
            "方案",
            "lcyjfapdf",
            "dir-042/file",
            "clinical_miss",
        ] {
            let norm_q = crate::norm(q);
            let t = Terms::parse(&norm_q);
            assert_eq!(
                summarize(large_index.search(&norm_q, t.as_ref(), 20)),
                summarize(search_full_scan(&large_index, &norm_q, t.as_ref(), 20)),
                "parallel parity mismatch for {q:?}"
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
