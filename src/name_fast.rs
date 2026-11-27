use crate::{Hit, Result, fts_phrase, row_hit};
use rusqlite::{Connection, OptionalExtension, params};
use std::{
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

#[path = "name_soa.rs"]
mod soa;
use soa::{NameIndex, default_index_budget};

// SQLite remains the query path while building or when the byte budget is exceeded.
const REBUILD_DELAY: Duration = Duration::from_millis(1200);
const OVER_BUDGET_DELAY: Duration = Duration::from_secs(30);
const MAX_BUILD_DELAY: Duration = Duration::from_secs(15 * 60);

pub(super) fn has_mtime(conn: &Connection) -> Result<bool> {
    Ok(conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM pragma_table_info('item') WHERE name='mtime')",
        [],
        |row| row.get(0),
    )?)
}

fn advance_bucket_sql(key: &str) -> String {
    format!(
        "INSERT INTO info(key,value) VALUES('{key}',1)
         ON CONFLICT(key) DO UPDATE SET value=CAST(value AS INTEGER)+1;"
    )
}

fn table_bucket_triggers(bucket_key: &str, tables: &[&str]) -> String {
    let advance = advance_bucket_sql(bucket_key);
    let mut sql = String::new();
    for table in tables {
        for (op, event) in [
            ("insert", "INSERT"),
            ("update", "UPDATE"),
            ("delete", "DELETE"),
        ] {
            sql.push_str(&format!(
                "CREATE TRIGGER IF NOT EXISTS {bucket_key}_{table}_{op} AFTER {event} ON {table} BEGIN {advance} END;"
            ));
        }
    }
    sql
}

fn info_bucket_triggers(bucket_key: &str, keys_sql: &str) -> String {
    let advance = advance_bucket_sql(bucket_key);
    format!(
        "CREATE TRIGGER IF NOT EXISTS {bucket_key}_info_insert AFTER INSERT ON info
         WHEN new.key {keys_sql} BEGIN {advance} END;
         CREATE TRIGGER IF NOT EXISTS {bucket_key}_info_update AFTER UPDATE ON info
         WHEN old.key {keys_sql} OR new.key {keys_sql} BEGIN {advance} END;
         CREATE TRIGGER IF NOT EXISTS {bucket_key}_info_delete AFTER DELETE ON info
         WHEN old.key {keys_sql} BEGIN {advance} END;"
    )
}

pub(super) fn install_generation(conn: &Connection) -> Result<()> {
    // Triggers also cover visibility changes and item writes outside the walker.
    let adv_name = advance_bucket_sql("name_generation");
    let adv_doc = advance_bucket_sql("doc_generation");
    let adv_vec = advance_bucket_sql("vec_generation");
    let adv_img = advance_bucket_sql("img_generation");
    let doc_triggers = table_bucket_triggers(
        "doc_generation",
        &["document", "document_state", "content_job"],
    );
    let vec_triggers = table_bucket_triggers(
        "vec_generation",
        &[
            "semantic_vector",
            "semantic_chunk",
            "semantic_state",
            "document",
            "document_state",
        ],
    );
    let img_triggers = table_bucket_triggers("img_generation", &["image_embedding", "image_scope"]);
    let doc_info = info_bucket_triggers("doc_generation", "IN ('scope','cloud_content_policy_v1')");
    let vec_info = info_bucket_triggers("vec_generation", "IN ('scope','model')");
    let img_info = info_bucket_triggers("img_generation", "= 'scope'");
    conn.execute_batch(&format!(
        "CREATE TABLE IF NOT EXISTS image_scope(id INTEGER PRIMARY KEY CHECK(id=1), root TEXT, epoch INTEGER NOT NULL);
         CREATE TABLE IF NOT EXISTS image_embedding(
             id INTEGER PRIMARY KEY, model TEXT NOT NULL, stamp TEXT NOT NULL, vector BLOB NOT NULL
         );
         INSERT OR IGNORE INTO info(key,value) VALUES('name_generation',0),('doc_generation',0),('vec_generation',0),('img_generation',0);
         CREATE TRIGGER IF NOT EXISTS item_name_generation_insert AFTER INSERT ON item BEGIN {adv_name} END;
         CREATE TRIGGER IF NOT EXISTS item_name_generation_delete AFTER DELETE ON item BEGIN {adv_name} END;
         DROP TRIGGER IF EXISTS item_name_generation_update;
         CREATE TRIGGER item_name_generation_update AFTER UPDATE ON item
         WHEN (old.id,old.path,old.display,old.kind,old.availability,old.name,old.full,old.initials,old.searchable_path,old.mtime)
           IS NOT (new.id,new.path,new.display,new.kind,new.availability,new.name,new.full,new.initials,new.searchable_path,new.mtime)
         BEGIN {adv_name} END;
         {doc_triggers}
         {doc_info}
         CREATE TRIGGER IF NOT EXISTS doc_generation_item_update AFTER UPDATE ON item
         WHEN (old.availability IS NOT new.availability OR old.path IS NOT new.path OR old.kind IS NOT new.kind)
           AND EXISTS(SELECT 1 FROM document WHERE id=old.id)
         BEGIN {adv_doc} END;
         CREATE TRIGGER IF NOT EXISTS doc_generation_item_delete AFTER DELETE ON item
         WHEN EXISTS(SELECT 1 FROM document WHERE id=old.id)
         BEGIN {adv_doc} END;
         {vec_triggers}
         {vec_info}
         CREATE TRIGGER IF NOT EXISTS vec_generation_item_update AFTER UPDATE ON item
         WHEN (old.availability IS NOT new.availability OR old.path IS NOT new.path OR old.kind IS NOT new.kind)
           AND (EXISTS(SELECT 1 FROM document WHERE id=old.id) OR EXISTS(SELECT 1 FROM semantic_chunk WHERE document_id=old.id))
         BEGIN {adv_vec} END;
         CREATE TRIGGER IF NOT EXISTS vec_generation_item_delete AFTER DELETE ON item
         WHEN EXISTS(SELECT 1 FROM document WHERE id=old.id) OR EXISTS(SELECT 1 FROM semantic_chunk WHERE document_id=old.id)
         BEGIN {adv_vec} END;
         {img_triggers}
         {img_info}
         CREATE TRIGGER IF NOT EXISTS img_generation_item_update AFTER UPDATE ON item
         WHEN (old.availability IS NOT new.availability OR old.path IS NOT new.path OR old.kind IS NOT new.kind)
           AND EXISTS(SELECT 1 FROM image_embedding WHERE id=old.id)
         BEGIN {adv_img} END;
         CREATE TRIGGER IF NOT EXISTS img_generation_item_delete AFTER DELETE ON item
         WHEN EXISTS(SELECT 1 FROM image_embedding WHERE id=old.id)
         BEGIN {adv_img} END;"
    ))?;
    Ok(())
}

pub(super) fn has_generation_buckets(conn: &Connection) -> Result<bool> {
    Ok(conn
        .prepare_cached(
            "SELECT (SELECT count(*)=4 FROM info WHERE key IN ('name_generation','doc_generation','vec_generation','img_generation'))
             AND EXISTS(SELECT 1 FROM sqlite_schema WHERE type='trigger' AND name='img_generation_image_embedding_insert')",
        )?
        .query_row([], |row| row.get(0))?)
}

pub(crate) fn bucket_generation(conn: &Connection, key: &str) -> Result<i64> {
    let value: Option<i64> = conn
        .prepare_cached("SELECT CAST(value AS INTEGER) FROM info WHERE key=?1")?
        .query_row([key], |row| row.get(0))
        .optional()?;
    match value {
        Some(generation) => Ok(generation),
        None => data_version(conn),
    }
}

pub(super) fn name_generation(conn: &Connection) -> Result<Option<i64>> {
    Ok(conn
        .prepare_cached("SELECT CAST(value AS INTEGER) FROM info WHERE key='name_generation'")?
        .query_row([], |row| row.get(0))
        .optional()?)
}

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
    if query.contains(['\0', '/']) || !literal_prefix_safe(query) {
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

// Filenames are normalized display basenames, so a two-Han suffix in a
// name is also a suffix of its normalized absolute path. The partial index
// stores only such endings, including extensionless names and directories.
const CREATE_HAN_ENDING: &str =
    "CREATE INDEX IF NOT EXISTS item_name_han_ending ON item(substr(name,-2))
     WHERE availability<>'unverified' AND substr(name,-2) GLOB '[㐀-鿿][㐀-鿿]'";

pub(super) fn install_han_ending(conn: &Connection) {
    if let Err(error) = conn.execute_batch(CREATE_HAN_ENDING) {
        eprintln!("lumen: could not build short Han name index: {error}");
    }
}

const MAX_HAN_OCCURRENCES: i64 = 8192;
const MAX_HAN_NAME_OCCURRENCES: i64 = 200_000;

// For any occurrence that is not at the end of a field, its next scalar is
// the third scalar of an existing FTS5 trigram. Seek that prefix in the
// vocabulary and union its item IDs with the indexed terminal occurrences.
// Keep the bounded candidate check, visibility filter and ranking in one
// statement, so a concurrently committed change can't split their snapshots.
const SHORT_HAN_SQL: &str = "
    WITH occurrences AS MATERIALIZED (
        SELECT doc AS id FROM temp.lumen_name_terms WHERE term>=?1 AND term<?2 LIMIT (?4+1)
    ), endings AS MATERIALIZED (
        SELECT id FROM item INDEXED BY item_name_han_ending
        WHERE availability<>'unverified' AND substr(name,-2) GLOB '[㐀-鿿][㐀-鿿]'
          AND substr(name,-2)=?1 LIMIT (?4+1)
    ), checked AS MATERIALIZED (
        SELECT (SELECT count(*) FROM occurrences)+(SELECT count(*) FROM endings)>?4 AS too_many
    ), candidates AS MATERIALIZED (
        SELECT id FROM occurrences WHERE NOT (SELECT too_many FROM checked)
        UNION
        SELECT id FROM endings WHERE NOT (SELECT too_many FROM checked)
    ), ranked AS MATERIALIZED (
        SELECT i.path,i.display,i.kind,i.availability,
               CASE WHEN instr(i.name,?1)>0 THEN 'name'
                    WHEN instr(i.full,?1)>0 OR instr(i.initials,?1)>0 THEN 'pinyin'
                    ELSE 'path' END AS matched_by,
               CASE WHEN i.name=?1 THEN 0 WHEN instr(i.name,?1)=1 THEN 1
                    WHEN instr(i.name,?1)>0 THEN 2
                    WHEN instr(i.full,?1)>0 OR instr(i.initials,?1)>0 THEN 3 ELSE 4 END AS rank,
               length(i.display) AS width
        FROM candidates c JOIN item i ON i.id=c.id
        WHERE i.availability<>'unverified'
          AND (instr(i.name,?1)>0 OR instr(i.full,?1)>0 OR instr(i.initials,?1)>0
               OR instr(i.searchable_path,?1)>0)
        ORDER BY rank,width,i.path LIMIT ?3
    )
    SELECT path,display,kind,availability,matched_by,rank,width FROM ranked
    UNION ALL
    SELECT NULL,NULL,NULL,NULL,NULL,-1,0 FROM checked WHERE too_many
    ORDER BY rank,width,path";

// Filename-only variant for disk fallback when path occurrences flood 8,192.
// A full page of rank 0..=2 basename hits cannot be displaced by pinyin/path hits.
const SHORT_HAN_NAME_SQL: &str = "
    WITH occurrences AS MATERIALIZED (
        SELECT doc AS id FROM temp.lumen_name_terms WHERE term>=?1 AND term<?2 AND col='name' LIMIT (?4+1)
    ), endings AS MATERIALIZED (
        SELECT id FROM item INDEXED BY item_name_han_ending
        WHERE availability<>'unverified' AND substr(name,-2) GLOB '[㐀-鿿][㐀-鿿]'
          AND substr(name,-2)=?1 LIMIT (?4+1)
    ), checked AS MATERIALIZED (
        SELECT (SELECT count(*) FROM occurrences)+(SELECT count(*) FROM endings)>?4 AS too_many
    ), candidates AS MATERIALIZED (
        SELECT id FROM occurrences WHERE NOT (SELECT too_many FROM checked)
        UNION
        SELECT id FROM endings WHERE NOT (SELECT too_many FROM checked)
    ), ranked AS MATERIALIZED (
        SELECT i.path,i.display,i.kind,i.availability,'name' AS matched_by,
               CASE WHEN i.name=?1 THEN 0 WHEN instr(i.name,?1)=1 THEN 1 ELSE 2 END AS rank,
               length(i.display) AS width
        FROM candidates c JOIN item i ON i.id=c.id
        WHERE i.availability<>'unverified' AND instr(i.name,?1)>0
        ORDER BY rank,width,i.path LIMIT ?3
    )
    SELECT path,display,kind,availability,matched_by,rank,width FROM ranked
    UNION ALL
    SELECT NULL,NULL,NULL,NULL,NULL,-1,0 FROM checked WHERE too_many
    ORDER BY rank,width,path";

fn run_short_han_query(
    conn: &Connection,
    sql: &str,
    query: &str,
    limit: usize,
    max_occurrences: i64,
) -> Result<Option<Vec<Hit>>> {
    let mut chars = query.chars();
    let han = |c| matches!(c, '㐀'..='鿿');
    if !(chars.next().is_some_and(han) && chars.next().is_some_and(han) && chars.next().is_none()) {
        return Ok(None);
    }
    let installed: bool = conn
        .prepare_cached("SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE name='item_name_han_ending' AND type='index')")?
        .query_row([], |row| row.get(0))?;
    if !installed {
        return Ok(None);
    }
    // The vocabulary is a view of committed FTS postings in this connection,
    // so this does not add a table to the catalog or need a writer at query time.
    conn.execute_batch(
        "CREATE VIRTUAL TABLE IF NOT EXISTS temp.lumen_name_terms USING fts5vocab(main, name_fts, instance)",
    )?;
    let upper = prefix_end(query).expect("a two-Han query has an upper bound");
    let mut stmt = conn.prepare_cached(sql)?;
    let mut rows = stmt.query(params![query, upper, limit as i64, max_occurrences])?;
    let mut hits = Vec::new();
    while let Some(row) = rows.next()? {
        if row.get::<_, i64>(5)? < 0 {
            return Ok(None);
        }
        hits.push(row_hit(row, &row.get::<_, String>(4)?)?);
    }
    Ok(Some(hits))
}

fn ranked_short_han(conn: &Connection, query: &str, limit: usize) -> Result<Option<Vec<Hit>>> {
    run_short_han_query(conn, SHORT_HAN_SQL, query, limit, MAX_HAN_OCCURRENCES)
}

fn ranked_short_han_names(
    conn: &Connection,
    query: &str,
    limit: usize,
) -> Result<Option<Vec<Hit>>> {
    Ok(run_short_han_query(
        conn,
        SHORT_HAN_NAME_SQL,
        query,
        limit,
        MAX_HAN_NAME_OCCURRENCES,
    )?
    .and_then(|hits| (hits.len() == limit).then_some(hits)))
}

/// A bounded disk candidate set for a structured query with only short
/// terms. The accelerator returns every match or falls back, never a page.
pub(super) fn short_han_seed(conn: &Connection, words: &[String]) -> Result<Option<Vec<String>>> {
    for word in words {
        if let Some(hits) = ranked_short_han(conn, word, MAX_HAN_OCCURRENCES as usize)? {
            return Ok(Some(hits.into_iter().map(|hit| hit.path).collect()));
        }
    }
    Ok(None)
}

pub(super) fn search_disk(conn: &Connection, query: &str, limit: usize) -> Result<Vec<Hit>> {
    if let Some(hits) = ranked_prefix(conn, query, limit)? {
        return Ok(hits);
    }
    if let Some(hits) = ranked_short_han_names(conn, query, limit)? {
        return Ok(hits);
    }
    if let Some(hits) = ranked_short_han(conn, query, limit)? {
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
    worker: JoinHandle<Result<Option<(i64, NameIndex)>>>,
}

pub(super) struct NameFast {
    db: PathBuf,
    loaded_generation: Option<i64>,
    building_generation: Option<i64>,
    index: Option<NameIndex>,
    build: Option<Build>,
    next_build: Instant,
    build_delay: Duration,
    budget: usize,
}

pub(super) fn data_version(conn: &Connection) -> Result<i64> {
    Ok(conn.pragma_query_value(None, "data_version", |row| row.get(0))?)
}

fn drop_off_hot_path(index: Option<NameIndex>) {
    if let Some(index) = index
        && let Err(error) = thread::Builder::new()
            .name("lumen-names-drop".to_owned())
            .spawn(move || drop(index))
    {
        drop(error);
    }
}

impl NameFast {
    pub(super) fn new(db: &Path, conn: &Connection) -> Self {
        Self::with_budget(db, conn, default_index_budget())
    }

    fn with_budget(db: &Path, conn: &Connection, budget: usize) -> Self {
        let mut fast = Self {
            db: db.to_owned(),
            loaded_generation: None,
            building_generation: None,
            index: None,
            build: None,
            next_build: Instant::now(),
            build_delay: OVER_BUDGET_DELAY,
            budget,
        };
        if let Ok(Some(generation)) = name_generation(conn) {
            fast.start(generation);
        }
        fast
    }

    pub(super) fn search(
        &mut self,
        conn: &Connection,
        query: &str,
        terms: Option<&crate::query::Terms>,
        limit: usize,
    ) -> Result<Option<(i64, Vec<Hit>)>> {
        let generation = name_generation(conn)?;
        if let Some(build) = &self.build
            && build.worker.is_finished()
        {
            let build = self.build.take().unwrap();
            let _building = self.building_generation.take();
            match build.worker.join() {
                Ok(Ok(Some((built_gen, index)))) => {
                    self.build_delay = OVER_BUDGET_DELAY;
                    let previous = self.index.replace(index);
                    drop_off_hot_path(previous);
                    self.loaded_generation = Some(built_gen);
                    if generation.is_some_and(|current| current != built_gen) {
                        self.next_build = Instant::now() + REBUILD_DELAY;
                    }
                }
                _ if !build.cancel.load(Ordering::Relaxed) => self.back_off(),
                _ => {}
            }
        }
        if let Some(generation) = generation {
            let current = self.loaded_generation == Some(generation);
            if self.build.is_none()
                && (!current || self.index.is_none())
                && Instant::now() >= self.next_build
            {
                self.start(generation);
            }
            if current && !query.contains('\0') {
                return Ok(self
                    .index
                    .as_ref()
                    .map(|index| (generation, index.search(query, terms, limit))));
            }
        }
        Ok(None)
    }

    fn back_off(&mut self) {
        self.next_build = Instant::now() + self.build_delay;
        self.build_delay = (2 * self.build_delay).min(MAX_BUILD_DELAY);
    }

    fn start(&mut self, generation: i64) {
        let db = self.db.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let cancellation = Arc::clone(&cancel);
        self.building_generation = Some(generation);
        self.next_build = Instant::now() + REBUILD_DELAY;
        let budget = self.budget;
        self.build = thread::Builder::new()
            .name("lumen-names".to_owned())
            .spawn(move || NameIndex::load(&db, &cancellation, budget))
            .ok()
            .map(|worker| Build { cancel, worker });
        if self.build.is_none() {
            self.building_generation = None;
            self.back_off();
        }
    }
}

impl Drop for NameFast {
    fn drop(&mut self) {
        if let Some(build) = &self.build {
            build.cancel.store(true, Ordering::Relaxed);
        }
    }
}

fn literal_prefix_safe(query: &str) -> bool {
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

#[cfg(test)]
struct TestPause {
    entered: (std::sync::Mutex<bool>, std::sync::Condvar),
    released: (std::sync::Mutex<bool>, std::sync::Condvar),
}

#[cfg(test)]
impl TestPause {
    fn new() -> Self {
        Self {
            entered: (std::sync::Mutex::new(false), std::sync::Condvar::new()),
            released: (std::sync::Mutex::new(false), std::sync::Condvar::new()),
        }
    }

    fn wait_entered(&self) {
        let mut entered = self.entered.0.lock().unwrap();
        while !*entered {
            entered = self.entered.1.wait(entered).unwrap();
        }
    }

    fn release(&self) {
        *self.released.0.lock().unwrap() = true;
        self.released.1.notify_all();
    }
}

#[cfg(test)]
fn test_pause_registry()
-> &'static std::sync::Mutex<std::collections::HashMap<PathBuf, Arc<TestPause>>> {
    static REGISTRY: std::sync::OnceLock<
        std::sync::Mutex<std::collections::HashMap<PathBuf, Arc<TestPause>>>,
    > = std::sync::OnceLock::new();
    REGISTRY.get_or_init(Default::default)
}

#[cfg(test)]
fn install_test_pause(db: &Path) -> Arc<TestPause> {
    let pause = Arc::new(TestPause::new());
    test_pause_registry()
        .lock()
        .unwrap()
        .insert(db.to_path_buf(), Arc::clone(&pause));
    pause
}

#[cfg(test)]
pub(super) fn maybe_pause_load_for_test(db: &Path) {
    let pause = test_pause_registry().lock().unwrap().remove(db);
    if let Some(pause) = pause {
        *pause.entered.0.lock().unwrap() = true;
        pause.entered.1.notify_all();
        let mut released = pause.released.0.lock().unwrap();
        while !*released {
            released = pause.released.1.wait(released).unwrap();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::open_read;
    use std::fs;

    struct Catalog(PathBuf);

    impl Catalog {
        fn new(case: &str) -> Result<Self> {
            let path =
                std::env::temp_dir().join(format!("lumen-names-{}-{case}", std::process::id()));
            fs::create_dir(&path)?;
            Ok(Self(path))
        }

        fn db(&self) -> PathBuf {
            fs::canonicalize(&self.0).unwrap().join("index.sqlite")
        }
    }

    impl Drop for Catalog {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn finish_build(fast: &NameFast) {
        let worker = &fast.build.as_ref().unwrap().worker;
        let deadline = Instant::now() + Duration::from_secs(30);
        while !worker.is_finished() {
            assert!(Instant::now() < deadline, "name build did not complete");
            thread::yield_now();
        }
    }

    #[test]
    fn independent_generation_buckets_isolate_domain_writes_and_configure_pragmas() -> Result<()> {
        let catalog = Catalog::new("buckets")?;
        let db = catalog.db();
        let (writer, _) = crate::open_write(&db, false)?;
        let reader = open_read(&db)?;

        let pragma = |conn: &Connection, name: &str| -> Result<i64> {
            Ok(conn.pragma_query_value(None, name, |row| row.get(0))?)
        };
        assert_eq!(pragma(&writer, "wal_autocheckpoint")?, 1000);
        assert_eq!(pragma(&writer, "journal_size_limit")?, 67_108_864);
        assert_eq!(pragma(&writer, "cache_size")?, -16_000);
        assert_eq!(pragma(&reader, "cache_size")?, -8_000);

        let generations = |conn: &Connection| -> Result<(i64, i64, i64, i64)> {
            Ok((
                bucket_generation(conn, "name_generation")?,
                bucket_generation(conn, "doc_generation")?,
                bucket_generation(conn, "vec_generation")?,
                bucket_generation(conn, "img_generation")?,
            ))
        };
        assert_eq!(generations(&reader)?, (0, 0, 0, 0));

        // Plain item writes bump only name_generation.
        writer.execute_batch(
            "INSERT INTO item VALUES(1,'/scope/a.txt','a.txt','file','local','a.txt','','','/scope/a.txt',10);
             INSERT INTO item VALUES(2,'/scope/b.png','b.png','file','local','b.png','','','/scope/b.png',10);
             INSERT INTO item VALUES(3,'/scope/c.txt','c.txt','file','local','c.txt','','','/scope/c.txt',10);
             UPDATE item SET mtime=20 WHERE id=3;",
        )?;
        assert_eq!(generations(&reader)?, (4, 0, 0, 0));

        // content_job affects only doc_generation.
        writer.execute_batch("INSERT INTO content_job VALUES(1, NULL);")?;
        assert_eq!(generations(&reader)?, (4, 1, 0, 0));

        // document / document_state affect doc_generation and vec_generation, not name or img.
        writer.execute_batch(
            "INSERT INTO document VALUES(1,'body','body');
             INSERT INTO document_state VALUES(1,'1:2:3:4:5');",
        )?;
        assert_eq!(generations(&reader)?, (4, 3, 2, 0));

        // semantic_chunk / semantic_vector affect only vec_generation.
        writer.execute_batch(
            "INSERT INTO semantic_chunk(id,document_id,start_byte,end_byte) VALUES(1,1,0,4);
             INSERT INTO semantic_vector VALUES('gemma',1,zeroblob(16));",
        )?;
        assert_eq!(generations(&reader)?, (4, 3, 4, 0));

        // image_scope / image_embedding affect only img_generation.
        writer.execute_batch(
            "INSERT INTO image_scope VALUES(1,'/scope',1);
             INSERT INTO image_embedding VALUES(2,'model','1:2:3:4:5',zeroblob(16));",
        )?;
        assert_eq!(generations(&reader)?, (4, 3, 4, 2));

        // Updating availability on an item referenced by document bumps name, doc, vec (not img).
        writer.execute_batch("UPDATE item SET availability='unverified' WHERE id=1;")?;
        assert_eq!(generations(&reader)?, (5, 4, 5, 2));

        // Updating availability on an item referenced by image_embedding (even without image_entry_moved) bumps name and img.
        writer.execute_batch("UPDATE item SET availability='unverified' WHERE id=2;")?;
        assert_eq!(generations(&reader)?, (6, 4, 5, 3));

        // Updating scope bumps doc, vec, img (not name).
        writer.execute_batch("INSERT INTO info(key,value) VALUES('scope','{}');")?;
        assert_eq!(generations(&reader)?, (6, 5, 6, 4));

        // Updating model bumps only vec_generation.
        writer.execute_batch("INSERT INTO info(key,value) VALUES('model','bge');")?;
        assert_eq!(generations(&reader)?, (6, 5, 7, 4));
        Ok(())
    }

    #[test]
    fn burst_writes_do_not_cancel_or_discard_active_name_index_build() -> Result<()> {
        let catalog = Catalog::new("burst-coalesce")?;
        let db = catalog.db();
        let (writer, _) = crate::open_write(&db, false)?;
        writer.execute(
            "INSERT INTO item VALUES(1,'/scope/alpha.txt','alpha.txt','file','local','alpha.txt','','','/scope/alpha.txt',10)",
            [],
        )?;
        let reader = open_read(&db)?;
        let mut fast = NameFast::new(&db, &reader);
        finish_build(&fast);
        let (gen0, hits) = fast.search(&reader, "alpha", None, 10)?.unwrap();
        assert_eq!(hits[0].name, "alpha.txt");
        assert_eq!(fast.loaded_generation, Some(gen0));

        // Arm a pause gate inside NameIndex::load so the gen1 rebuild stays active across burst writes.
        let gate = install_test_pause(&db);
        writer.execute(
            "INSERT INTO item VALUES(2,'/scope/beta.txt','beta.txt','file','local','beta.txt','','','/scope/beta.txt',20)",
            [],
        )?;
        fast.next_build = Instant::now();
        assert!(fast.search(&reader, "beta", None, 10)?.is_none());
        assert!(fast.build.is_some());
        // Warm NameIndex from gen0 stays intact in memory while the rebuild runs.
        assert!(fast.index.is_some());
        assert_eq!(fast.loaded_generation, Some(gen0));
        gate.wait_entered();

        // Commit a burst of item mutations while gen1 rebuild is mid-flight.
        for (id, name) in [(3, "gamma.txt"), (4, "delta.txt"), (5, "epsilon.txt")] {
            writer.execute(
                "INSERT INTO item VALUES(?1,?2,?3,'file','local',?3,'','',?2,30)",
                params![id, format!("/scope/{name}"), name],
            )?;
            // Must NOT cancel the active build or discard the warm index; must fall back cleanly.
            assert!(fast.search(&reader, "epsilon", None, 10)?.is_none());
            let build = fast
                .build
                .as_ref()
                .expect("active build must remain running");
            assert!(
                !build.cancel.load(Ordering::Relaxed),
                "burst writes must not cancel active NameIndex build"
            );
            assert!(fast.index.is_some(), "warm NameIndex must not be discarded");
        }

        // Release the active gen1 build and let it swap in cleanly.
        gate.release();
        finish_build(&fast);
        let stale_gen = gen0 + 1;
        let final_gen = gen0 + 4;
        assert_eq!(name_generation(&reader)?, Some(final_gen));
        // Because loaded_generation (stale_gen) != final_gen, query falls back to SQLite and
        // schedules one coalesced follow-up rebuild after REBUILD_DELAY (1200ms).
        let before_swap = Instant::now();
        assert!(fast.search(&reader, "epsilon", None, 10)?.is_none());
        assert_eq!(fast.loaded_generation, Some(stale_gen));
        assert!(fast.build.is_none());
        assert!(fast.next_build >= before_swap + REBUILD_DELAY);

        // Once the coalesced delay elapses, one rebuild converges to final_gen.
        fast.next_build = Instant::now();
        assert!(fast.search(&reader, "epsilon", None, 10)?.is_none());
        assert!(fast.build.is_some());
        finish_build(&fast);
        let (ram_gen, ram_hits) = fast.search(&reader, "epsilon", None, 10)?.unwrap();
        assert_eq!(ram_gen, final_gen);
        assert_eq!(ram_hits[0].name, "epsilon.txt");
        Ok(())
    }

    #[test]
    fn writer_open_does_not_require_a_write_lock_after_migration() -> Result<()> {
        let catalog = Catalog::new("writer-lock")?;
        let db = catalog.db();
        let (conn, _) = crate::open_write(&db, false)?;
        conn.execute_batch(
            "BEGIN IMMEDIATE; INSERT INTO info VALUES('test','active transaction');",
        )?;
        let (other, _) = crate::open_write(&db, false)?;
        assert_eq!(name_generation(&other)?, Some(0));
        conn.execute_batch("ROLLBACK;")?;
        Ok(())
    }

    #[test]
    fn background_writes_keep_name_index_but_item_changes_invalidate_it() -> Result<()> {
        let catalog = Catalog::new("generation")?;
        let db = catalog.db();
        let (writer, _) = crate::open_write(&db, false)?;
        writer.execute_batch(
            "INSERT INTO item VALUES(1,'/scope/example','example','file','local','example','','','/scope/example',0);",
        )?;
        let reader = open_read(&db)?;
        let mut fast = NameFast::new(&db, &reader);
        finish_build(&fast);
        let (generation, hits) = fast.search(&reader, "example", None, 10)?.unwrap();
        assert_eq!(hits[0].name, "example");
        let version = data_version(&reader)?;
        writer.execute_batch(
            "INSERT INTO document VALUES(1,'a document','a document');
             INSERT INTO embedding VALUES(1,zeroblob(32));
             UPDATE item SET availability=availability WHERE id=1;",
        )?;
        assert_ne!(version, data_version(&reader)?);
        assert_eq!(
            fast.search(&reader, "example", None, 10)?.unwrap().0,
            generation
        );
        writer.execute_batch("UPDATE item SET mtime=123 WHERE id=1;")?;
        assert_eq!(name_generation(&reader)?, Some(generation + 1));
        writer.execute_batch("UPDATE item SET availability='unverified' WHERE id=1;")?;
        assert_eq!(name_generation(&reader)?, Some(generation + 2));
        assert!(fast.search(&reader, "example", None, 10)?.is_none());
        writer.execute_batch("DELETE FROM item WHERE id=1;")?;
        assert_eq!(name_generation(&reader)?, Some(generation + 3));
        Ok(())
    }

    #[test]
    fn ready_soa_handles_non_ascii_single_words_without_fts() -> Result<()> {
        let catalog = Catalog::new("unicode-word")?;
        let db = catalog.db();
        let (writer, _) = crate::open_write(&db, false)?;
        for (path, name) in [
            ("/scope/Résumé", "Résumé"),
            ("/scope/Mon résumé.txt", "Mon résumé.txt"),
            ("/scope/Résumés/notes.txt", "notes.txt"),
            ("/scope/Resume.txt", "Resume.txt"),
        ] {
            writer.execute(
                "INSERT INTO item VALUES(NULL,?1,?2,'file','local',?3,'','',?4,0)",
                params![path, name, crate::norm(name), crate::norm(path)],
            )?;
        }
        // No FTS rows: require the RAM route, including normalization of
        // decomposed accented input and matches in both basenames and paths.
        let reader = open_read(&db)?;
        let mut fast = NameFast::new(&db, &reader);
        let query = "RE\u{301}SUME\u{301}";
        let normalized = crate::norm(query);
        assert!(crate::query::Terms::parse(&normalized).is_none());
        finish_build(&fast);
        let hits =
            crate::search_with_names(&reader, query, crate::Mode::Name, 20, None, Some(&mut fast))?;
        assert_eq!(
            hits.iter()
                .map(|hit| (hit.name.as_str(), hit.matched_by.as_str()))
                .collect::<Vec<_>>(),
            [
                ("Résumé", "name"),
                ("Mon résumé.txt", "name"),
                ("notes.txt", "path")
            ],
        );
        Ok(())
    }

    #[test]
    fn ready_soa_matches_disk_for_greek_final_sigma() -> Result<()> {
        let catalog = Catalog::new("final-sigma")?;
        let db = catalog.db();
        let (writer, _) = crate::open_write(&db, false)?;
        for (path, name) in [
            ("/scope/κόσμος", "κόσμος"),
            ("/scope/κόσμοσ", "κόσμοσ"),
            ("/scope/κόσμος-archive/notes", "notes"),
            ("/scope/κοσμος", "κοσμος"),
        ] {
            writer.execute(
                "INSERT INTO item VALUES(NULL,?1,?2,'file','local',?3,'','',?4,0)",
                params![path, name, crate::norm(name), crate::norm(path)],
            )?;
        }
        writer.execute_batch(
            "INSERT INTO name_fts(rowid,name,full,initials,searchable_path)
             SELECT id,name,full,initials,searchable_path FROM item;",
        )?;
        let reader = open_read(&db)?;
        let mut fast = NameFast::new(&db, &reader);
        let matches = |hits: Vec<Hit>| {
            hits.into_iter()
                .map(|hit| (hit.path, hit.matched_by))
                .collect::<Vec<_>>()
        };
        for (query, expected) in [
            (
                "ΚΌΣΜΟΣ",
                [
                    ("/scope/κόσμοσ", "name"),
                    ("/scope/κόσμος-archive/notes", "path"),
                    ("/scope/κόσμος", "path"),
                ],
            ),
            (
                "κόσμος",
                [
                    ("/scope/κόσμος", "name"),
                    ("/scope/κόσμος-archive/notes", "path"),
                    ("/scope/κόσμοσ", "path"),
                ],
            ),
        ] {
            let cold = matches(crate::search_with_names(
                &reader,
                query,
                crate::Mode::Name,
                20,
                None,
                None,
            )?);
            assert_eq!(
                cold,
                expected.map(|(path, by)| (path.to_owned(), by.to_owned()))
            );
            if fast.build.is_some() {
                finish_build(&fast);
            }
            let ready = matches(crate::search_with_names(
                &reader,
                query,
                crate::Mode::Name,
                20,
                None,
                Some(&mut fast),
            )?);
            assert!(fast.index.is_some(), "the test must use the RAM snapshot");
            assert_eq!(ready, cold, "cold and ready results for {query}");
        }
        Ok(())
    }

    #[test]
    fn over_budget_catalog_backs_off_across_generations() -> Result<()> {
        let catalog = Catalog::new("over-budget")?;
        let db = catalog.db();
        let (writer, _) = crate::open_write(&db, false)?;
        writer.execute_batch(
            "INSERT INTO item VALUES(1,'/scope/fixture','fixture','file','local','fixture','','','/scope/fixture',0);",
        )?;
        let reader = open_read(&db)?;
        let mut fast = NameFast::with_budget(&db, &reader, 64);
        finish_build(&fast);
        let t = Instant::now();
        assert!(fast.search(&reader, "fixture", None, 10)?.is_none());
        assert!(fast.next_build >= t + OVER_BUDGET_DELAY);
        writer.execute_batch("UPDATE item SET kind='directory' WHERE id=1;")?;
        assert!(fast.search(&reader, "fixture", None, 10)?.is_none());
        assert!(fast.build.is_none());
        // Advance the retry deadline without sleeping; the same catalog is still oversized.
        fast.next_build = Instant::now();
        assert!(fast.search(&reader, "fixture", None, 10)?.is_none());
        finish_build(&fast);
        let t = Instant::now();
        assert!(fast.search(&reader, "fixture", None, 10)?.is_none());
        assert!(fast.next_build >= t + 2 * OVER_BUDGET_DELAY);
        Ok(())
    }

    #[test]
    fn soa_scales_past_the_old_row_cap() -> Result<()> {
        let catalog = Catalog::new("large-soa")?;
        let db = catalog.db();
        let (writer, _) = crate::open_write(&db, false)?;
        writer.execute_batch(
            "WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<510001),
             names(id,name) AS (SELECT n,printf('report-%06d.pdf',n) FROM numbers)
             INSERT INTO item SELECT id,'/scope/'||name,name,'file','local',name,'','','/scope/'||name,0 FROM names;",
        )?;
        let reader = open_read(&db)?;
        let mut fast = NameFast::new(&db, &reader);
        finish_build(&fast);
        let q = "report 510001 kind:doc ext:pdf /scope/";
        let (_, hits) = fast
            .search(&reader, q, crate::query::Terms::parse(q).as_ref(), 20)?
            .expect("the 510,001-row catalog must publish a RAM snapshot");
        assert_eq!(
            hits.iter().map(|h| h.path.as_str()).collect::<Vec<_>>(),
            ["/scope/report-510001.pdf"]
        );
        assert!(fast.index.as_ref().unwrap().capacity_bytes() < 70 * 1024 * 1024);
        Ok(())
    }

    #[test]
    fn soa_filters_path_pinyin_and_composite_rank() -> Result<()> {
        let catalog = Catalog::new("soa-filters")?;
        let db = catalog.db();
        let (writer, _) = crate::open_write(&db, false)?;
        let home = crate::absolute(Path::new(&std::env::var_os("HOME").expect("HOME")))?;
        let entries = [
            (home.join("Desktop/draft brief.pdf"), "file", "", 60),
            (home.join("Desktop/draft brief.png"), "file", "", 60),
            (home.join("Desktop/draft brief-old.pdf"), "file", "", 50),
            (
                home.join("Desktop/node_modules/draft brief.pdf"),
                "file",
                "",
                90,
            ),
            (PathBuf::from("/elsewhere/draft brief.pdf"), "file", "", 100),
            (home.join("Desktop/draft"), "directory", "", 40),
            (home.join("Desktop/draft.app"), "directory", "", 40),
            (
                home.join("Desktop/成都会报 winter.pdf"),
                "file",
                "chengdouhuibaowinterpdf",
                30,
            ),
            (
                home.join("Desktop-adjacent/draft brief.pdf"),
                "file",
                "",
                20,
            ),
            (home.join("Desktop/music.wav"), "file", "", 50),
            (home.join("Desktop/clip.mov"), "file", "", 50),
            (home.join("Desktop/main.rs"), "file", "", 50),
            (home.join("Desktop/backup.tar.gz"), "file", "", 50),
        ];
        for (path, kind, full, mtime) in &entries {
            let path = path.to_str().unwrap();
            let display = Path::new(path).file_name().unwrap().to_str().unwrap();
            writer.execute(
                "INSERT INTO item VALUES(NULL,?1,?2,?3,'local',?4,?5,'',?6,?7)",
                params![
                    path,
                    display,
                    kind,
                    crate::norm(display),
                    full,
                    crate::norm(path),
                    mtime
                ],
            )?;
        }
        let reader = open_read(&db)?;
        let mut fast = NameFast::new(&db, &reader);
        finish_build(&fast);
        // This fixture has no FTS rows; require a published snapshot for every search.
        let mut search = |q: &str| {
            fast.search(&reader, q, crate::query::Terms::parse(q).as_ref(), 20)
                .unwrap()
                .unwrap()
                .1
        };
        let ranked = search("draft");
        assert_eq!(ranked.len(), 8);
        for (hit, (path, ..)) in ranked
            .iter()
            .zip([5, 0, 1, 2, 6, 8, 4, 3].map(|i| &entries[i]))
        {
            // The two non-clean matches still sort by mtime, regardless of scope.
            assert_eq!(hit.path, path.to_str().unwrap());
        }
        let hits = search("~/desktop/ draft brief .pdf");
        assert_eq!(
            hits.iter().map(|h| h.path.as_str()).collect::<Vec<_>>(),
            [0, 2, 3].map(|i| entries[i].0.to_str().unwrap())
        );
        assert_eq!(
            search("chengdu winter ext:pdf kind:doc")[0].matched_by,
            "pinyin"
        );
        assert_eq!(search("desktop/draft brief").len(), 3);
        assert!(search("kind:doc kind:app").is_empty());
        for (kind, file) in [
            ("image", "draft brief.png"),
            ("video", "clip.mov"),
            ("audio", "music.wav"),
            ("code", "main.rs"),
            ("archive", "backup.tar.gz"),
            ("folder", "draft"),
            ("app", "draft.app"),
        ] {
            let hits = search(&format!("~/desktop/ kind:{kind}"));
            assert_eq!(
                hits.iter().map(|h| h.name.as_str()).collect::<Vec<_>>(),
                [file]
            );
        }
        Ok(())
    }

    #[test]
    fn short_han_candidate_limit_falls_back_without_truncating() -> Result<()> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch(
            "CREATE TABLE item(id INTEGER PRIMARY KEY, path TEXT, display TEXT, kind TEXT,
                              availability TEXT, name TEXT, full TEXT, initials TEXT, searchable_path TEXT);
             CREATE VIRTUAL TABLE name_fts USING fts5(name,full,initials,searchable_path,tokenize='trigram');",
        )?;
        install_han_ending(&conn);
        conn.execute(
            "WITH RECURSIVE seq(id) AS (VALUES(1) UNION ALL SELECT id+1 FROM seq WHERE id<?1)
             INSERT INTO item
             SELECT id,'/scope/'||id||'鹿鸣',id||'鹿鸣','file','local',
                    id||'鹿鸣','','','/scope/'||id||'鹿鸣'
             FROM seq",
            [MAX_HAN_OCCURRENCES + 1],
        )?;
        conn.execute(
            "INSERT INTO name_fts(rowid,name,full,initials,searchable_path)
                      SELECT id,name,full,initials,searchable_path FROM item",
            [],
        )?;
        assert!(ranked_short_han(&conn, "鹿鸣", 60)?.is_none());
        let hits = search_disk(&conn, "鹿鸣", 60)?;
        assert_eq!(hits.len(), 60);
        assert_eq!(hits[0].name, "1鹿鸣");
        Ok(())
    }

    #[test]
    fn short_han_names_skips_path_flood_and_matches_full_scan() -> Result<()> {
        let conn = Connection::open_in_memory()?;
        let baseline = Connection::open_in_memory()?;
        for db in [&conn, &baseline] {
            db.execute_batch(
                "CREATE TABLE item(id INTEGER PRIMARY KEY, path TEXT, display TEXT, kind TEXT,
                                  availability TEXT, name TEXT, full TEXT, initials TEXT, searchable_path TEXT);
                 CREATE VIRTUAL TABLE name_fts USING fts5(name,full,initials,searchable_path,tokenize='trigram');",
            )?;
            let mut next_id = 1_i64;
            let mut insert = |path: &str, name: &str| -> Result<()> {
                db.execute(
                    "INSERT INTO item VALUES(?1,?2,?3,'file','local',?3,'','',?4)",
                    params![next_id, path, name, path],
                )?;
                next_id += 1;
                Ok(())
            };
            for i in 0..9000 {
                insert(
                    &format!("/scope/方案目录/{i:04}-misc.txt"),
                    &format!("{i:04}-misc.txt"),
                )?;
            }
            insert("/scope/exact/方案", "方案")?;
            for i in 0..25 {
                insert(
                    &format!("/scope/prefix/方案{i:02}.md"),
                    &format!("方案{i:02}.md"),
                )?;
            }
            for i in 0..25 {
                insert(
                    &format!("/scope/mid/测试方案{i:02}.txt"),
                    &format!("测试方案{i:02}.txt"),
                )?;
            }
            for i in 0..20 {
                insert(
                    &format!("/scope/end/{i:02}试点方案"),
                    &format!("{i:02}试点方案"),
                )?;
            }
            insert("/scope/partial/青梅.txt", "青梅.txt")?;
            insert("/scope/partial/山前青梅", "山前青梅")?;
            for i in 0..3 {
                insert(
                    &format!("/scope/青梅目录/{i}-note.txt"),
                    &format!("{i}-note.txt"),
                )?;
            }
            db.execute(
                "INSERT INTO name_fts(rowid,name,full,initials,searchable_path)
                 SELECT id,name,full,initials,searchable_path FROM item",
                [],
            )?;
        }
        install_han_ending(&conn);

        assert!(ranked_short_han(&conn, "方案", 60)?.is_none());
        let shape = |hits: Vec<Hit>| {
            hits.into_iter()
                .map(|h| (h.path, h.name, h.kind, h.availability, h.matched_by))
                .collect::<Vec<_>>()
        };
        let fast = ranked_short_han_names(&conn, "方案", 60)?
            .expect("full basename page must bypass flooded path scan");
        let full = shape(search_disk(&baseline, "方案", 60)?);
        assert_eq!(fast.len(), 60);
        assert_eq!(shape(fast), full);
        assert_eq!(shape(search_disk(&conn, "方案", 60)?), full);

        assert!(ranked_short_han_names(&conn, "青梅", 60)?.is_none());
        let partial = search_disk(&conn, "青梅", 60)?;
        assert_eq!(
            partial
                .iter()
                .map(|h| (h.name.as_str(), h.matched_by.as_str()))
                .collect::<Vec<_>>(),
            [
                ("青梅.txt", "name"),
                ("山前青梅", "name"),
                ("0-note.txt", "path"),
                ("1-note.txt", "path"),
                ("2-note.txt", "path"),
            ]
        );
        assert_eq!(shape(partial), shape(search_disk(&baseline, "青梅", 60)?));
        Ok(())
    }
}
