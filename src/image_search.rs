use crate::{
    GemmaModel, Hit, Scope, absolute,
    content::has_table,
    diagnose::{local_stamp, read_snapshot},
    gemma::DIMENSIONS,
    image_decode::{MAX_FILE_BYTES, supported_path, thumbnail},
    open_read, open_write, platform, saved_index_scope,
    semantic::GemmaQuery,
    vector::{Matrix, MatrixCache, adaptive_floor, pack},
};
use anyhow::{Context, Result, bail, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::Serialize;
use std::{
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
};

pub const MODEL_ID: &str = "gemma2/image/imageio512-v1/q8_0/b11457/retrieval/768/l2/0531309472a6bc6f4b146c3736eee7795ec9db1903c25490d3c937490cef6dd8";
const MAX_VECTORS: i64 = 4096;
const MAX_BATCH: usize = 16;
// A minimum cosine for this exact model, not an estimate of correctness.
const MIN_COSINE: f32 = 0.65;
const Z_THRESHOLD: f64 = 1.0;
const LEGACY_VECTOR_BYTES: i64 = (DIMENSIONS * 4) as i64;
const IMAGE_LIVE: &str = "FROM image_embedding e JOIN item i USING(id)
    WHERE e.model=?1 AND i.path>=?2 AND i.path<?3 AND i.kind='file'
    AND i.availability IN ('local','provider_metadata_only')
    AND typeof(e.vector)='blob' AND length(e.vector) IN (?4/2,?4)";
const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS image_scope(id INTEGER PRIMARY KEY CHECK(id=1), root TEXT, epoch INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS image_embedding(
        id INTEGER PRIMARY KEY, model TEXT NOT NULL, stamp TEXT NOT NULL, vector BLOB NOT NULL
    );
    CREATE TRIGGER IF NOT EXISTS image_entry_deleted AFTER DELETE ON item
    BEGIN DELETE FROM image_embedding WHERE id=old.id; END;
    CREATE TRIGGER IF NOT EXISTS image_entry_moved AFTER UPDATE OF path, kind, availability ON item
    WHEN NEW.path != OLD.path OR NEW.kind != OLD.kind OR NEW.availability != OLD.availability
    BEGIN DELETE FROM image_embedding WHERE id=old.id; END;
";

#[derive(Debug, PartialEq, Eq)]
struct Rules {
    root: String,
    epoch: i64,
    names: Scope,
}

impl Rules {
    fn read(conn: &Connection) -> Result<Option<Self>> {
        if !has_table(conn, "image_scope")? {
            return Ok(None);
        }
        let scope: Option<(String, i64)> = conn
            .query_row(
                "SELECT root,epoch FROM image_scope WHERE id=1 AND root IS NOT NULL",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let Some((root, epoch)) = scope else {
            return Ok(None);
        };
        let names = saved_index_scope(conn)?.context("no filename index scope")?;
        Ok(Some(Self { root, epoch, names }))
    }

    fn allows(&self, path: &Path) -> bool {
        supported_path(path)
            && path.starts_with(&self.root)
            && path != Path::new(&self.root)
            && named_in(&self.names, path)
    }

    fn bounds(&self) -> (String, String) {
        (format!("{}/", self.root), format!("{}0", self.root))
    }
}

fn named_in(scope: &Scope, path: &Path) -> bool {
    !crate::external::is_external(path)
        && scope.roots.iter().any(|root| path.starts_with(root))
        && scope.allows(path)
}

#[derive(Serialize)]
pub struct ImageScopeStatus {
    root: Option<String>,
    vectors: i64,
}

/// Inspect the saved image opt-in and stored vector count without changing the database.
pub fn image_status(database: &Path) -> Result<ImageScopeStatus> {
    let conn = open_read(database)?;
    let snapshot = conn.unchecked_transaction()?;
    let Some(rules) = Rules::read(&snapshot)? else {
        return Ok(ImageScopeStatus {
            root: None,
            vectors: 0,
        });
    };
    let vectors = count_images(&snapshot, &rules)?;
    Ok(ImageScopeStatus {
        root: Some(rules.root),
        vectors,
    })
}

/// Set or clear an explicit image folder. No file bytes are read.
pub fn image_scope(database: &Path, root: Option<&Path>) -> Result<ImageScopeStatus> {
    #[cfg(target_os = "macos")]
    let _io = platform::NoMaterialization::enter()?;
    let database = absolute(database)?;
    drop(open_read(&database)?);
    let (mut conn, _lease) = open_write(&database, false)?;
    let txn = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let names = saved_index_scope(&txn)?.context("no filename index scope")?;
    let root = root
        .map(|path| -> Result<String> {
            let path = absolute(path)?;
            let path = platform::filesystem_spelling(&path);
            ensure!(
                path != Path::new("/")
                    && named_in(&names, &path)
                    && local_stamp(&path, true).is_some(),
                "choose a readable local image folder within the saved filename scope"
            );
            path.into_os_string()
                .into_string()
                .ok()
                .context("image folder path is not valid UTF-8")
        })
        .transpose()?;
    txn.execute_batch(SCHEMA)?;
    let changed = txn.execute(
        "INSERT INTO image_scope VALUES(1,?1,1)
         ON CONFLICT(id) DO UPDATE SET root=excluded.root,epoch=epoch+1
         WHERE root IS NOT excluded.root",
        [&root],
    )?;
    if changed != 0 {
        txn.execute("DELETE FROM image_embedding", [])?;
    }
    let vectors = Rules::read(&txn)?
        .as_ref()
        .map_or(Ok(0), |rules| count_images(&txn, rules))?;
    txn.commit()?;
    Ok(ImageScopeStatus { root, vectors })
}

fn count_images(conn: &Connection, rules: &Rules) -> Result<i64> {
    let (lower, upper) = rules.bounds();
    let mut stmt = conn.prepare_cached(&format!("SELECT i.path {IMAGE_LIVE}"))?;
    let mut rows = stmt.query(params![MODEL_ID, lower, upper, LEGACY_VECTOR_BYTES])?;
    let mut count = 0;
    while let Some(row) = rows.next()? {
        count += i64::from(rules.allows(Path::new(row.get_ref(0)?.as_str()?)));
    }
    Ok(count)
}

#[derive(Serialize)]
pub struct ImageBatch {
    pub model_id: &'static str,
    pub processed: usize,
    pub indexed: usize,
    pub reused: usize,
    pub skipped: usize,
    pub limited: bool,
    pub next_after: Option<String>,
}

trait ImageEncoder {
    fn encode_image_bytes(&mut self, bytes: &[u8]) -> Result<Vec<f32>>;
}

impl ImageEncoder for crate::gemma::GemmaWorker {
    fn encode_image_bytes(&mut self, bytes: &[u8]) -> Result<Vec<f32>> {
        self.encode_image(bytes)
    }
}

pub fn image_batch(
    database: &Path,
    model: &GemmaModel,
    projector: &Path,
    after: Option<&str>,
    max: usize,
) -> Result<ImageBatch> {
    ensure!(
        (1..=MAX_BATCH).contains(&max),
        "image batch size must be 1 through {MAX_BATCH}"
    );
    let database = absolute(database)?;
    let reader = open_read(&database)?;
    let mut writer = None;
    let mut worker = None;
    let mut connect = Some(|| model.start_images(projector));
    let (batch, _) = image_batch_step(
        &database,
        &reader,
        &mut writer,
        &mut connect,
        &mut worker,
        after,
        max,
        None,
        None,
        false,
    )?;
    Ok(batch
        .expect("non-streaming batch always returns a result")
        .0)
}

#[allow(clippy::too_many_arguments)]
fn image_batch_step<E: ImageEncoder>(
    database: &Path,
    reader: &Connection,
    writer: &mut Option<Connection>,
    connect: &mut Option<impl FnOnce() -> Result<E>>,
    worker: &mut Option<E>,
    after: Option<&str>,
    max: usize,
    expected_rules: Option<&Rules>,
    stop: Option<&AtomicBool>,
    yield_on_scope_change: bool,
) -> Result<(Option<(ImageBatch, Rules)>, bool)> {
    let snapshot = reader.unchecked_transaction()?;
    let current_rules = Rules::read(&snapshot)?;
    if let Some(expected) = expected_rules
        && current_rules.as_ref() != Some(expected)
    {
        return Ok((None, true));
    }
    let rules = current_rules.context("choose a folder with image-scope first")?;
    let (lower, upper) = rules.bounds();
    let after = after.unwrap_or("");
    ensure!(
        after.is_empty() || (after >= lower.as_str() && after < upper.as_str()),
        "image cursor is outside the selected folder"
    );
    let mut available = MAX_VECTORS
        - snapshot.query_row("SELECT count(*) FROM image_embedding", [], |r| {
            r.get::<_, i64>(0)
        })?;
    let rows = {
        let mut stmt = snapshot.prepare(
            "SELECT i.id,i.path,CASE WHEN e.model=?4 AND typeof(e.vector)='blob'
                AND length(e.vector) IN (?6/2,?6) THEN e.stamp END,e.id IS NOT NULL
             FROM item i LEFT JOIN image_embedding e ON i.id=e.id
             WHERE i.path>=?1 AND i.path<?2 AND i.path>?3
               AND i.kind='file' AND i.availability IN ('local','provider_metadata_only')
               AND (substr(lower(i.path),-4) IN ('.png','.jpg')
                 OR substr(lower(i.path),-5) IN ('.jpeg','.heic','.heif','.webp'))
             ORDER BY i.path LIMIT ?5",
        )?;
        stmt.query_map(
            params![
                lower,
                upper,
                after,
                MODEL_ID,
                max as i64 + 1,
                LEGACY_VECTOR_BYTES
            ],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, bool>(3)?,
                ))
            },
        )?
        .collect::<rusqlite::Result<Vec<_>>>()?
    };
    drop(snapshot);
    let total_rows = rows.len();
    let planned = total_rows.min(max);
    let mut batch = ImageBatch {
        model_id: MODEL_ID,
        processed: planned,
        indexed: 0,
        reused: 0,
        skipped: 0,
        limited: false,
        next_after: (total_rows > max).then(|| rows[max - 1].1.clone()),
    };
    let mut encoded = Vec::new();
    let mut stopped = false;
    let mut last_path = None;
    for (idx, (id, path, prior, occupied)) in rows.into_iter().take(max).enumerate() {
        if stop.is_some_and(|flag| flag.load(Ordering::Acquire)) {
            if idx == 0 {
                return Ok((None, true));
            }
            batch.processed = idx;
            batch.next_after = last_path.filter(|_| total_rows > idx);
            stopped = true;
            break;
        }
        if Rules::read(reader)?.as_ref() != Some(&rules) {
            if yield_on_scope_change {
                return Ok((None, true));
            }
            bail!("image or filename scope changed; retry the batch");
        }
        let source = Path::new(&path);
        let stamp = rules
            .allows(source)
            .then(|| local_stamp(source, false))
            .flatten();
        let Some(stamp) = stamp else {
            last_path = Some(path);
            batch.skipped += 1;
            continue;
        };
        if prior
            .as_deref()
            .is_some_and(|prior| crate::index::stamp_matches(prior, &stamp))
        {
            last_path = Some(path);
            batch.reused += 1;
            continue;
        }
        if !occupied && available <= 0 {
            last_path = Some(path);
            batch.limited = true;
            batch.skipped += 1;
            continue;
        }
        let Ok(bytes) = platform::read_local_checked(source, MAX_FILE_BYTES, Some(&stamp)) else {
            last_path = Some(path);
            batch.skipped += 1;
            continue;
        };
        let Some(bytes) = thumbnail(&bytes) else {
            last_path = Some(path);
            batch.skipped += 1;
            continue;
        };
        let worker = match worker {
            Some(worker) => worker,
            None => worker.insert(connect.take().expect("image worker connects once")()?),
        };
        let vector = worker.encode_image_bytes(&bytes)?;
        available -= i64::from(!occupied);
        last_path = Some(path.clone());
        encoded.push((id, path, stamp, pack(&vector)));
    }
    if encoded.is_empty() {
        return Ok((Some((batch, rules)), stopped));
    }

    if writer.is_none() {
        *writer = Some(open_write(database, false)?.0);
    }
    let conn = writer.as_mut().expect("opened writer connection");
    let txn = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if Rules::read(&txn)?.as_ref() != Some(&rules) {
        if yield_on_scope_change {
            return Ok((None, true));
        }
        bail!("image or filename scope changed; retry the batch");
    }
    let mut total: i64 = txn.query_row("SELECT count(*) FROM image_embedding", [], |r| r.get(0))?;
    for (id, path, stamp, packed) in encoded {
        let still_indexed: bool = txn.query_row(
            "SELECT EXISTS(SELECT 1 FROM item WHERE id=?1 AND path=?2 AND kind='file' AND availability IN ('local','provider_metadata_only'))",
            params![id, path],
            |r| r.get(0),
        )?;
        if !still_indexed
            || !local_stamp(Path::new(&path), false)
                .as_deref()
                .is_some_and(|live| crate::index::stamp_matches(&stamp, live))
        {
            batch.skipped += 1;
            continue;
        }
        let existing: bool = txn.query_row(
            "SELECT EXISTS(SELECT 1 FROM image_embedding WHERE id=?1)",
            [id],
            |r| r.get(0),
        )?;
        if !existing && total >= MAX_VECTORS {
            batch.skipped += 1;
            batch.limited = true;
            continue;
        }
        txn.execute(
            "INSERT INTO image_embedding VALUES (?1,?2,?3,?4)
             ON CONFLICT(id) DO UPDATE SET model=excluded.model,stamp=excluded.stamp,vector=excluded.vector",
            params![id, MODEL_ID, stamp, packed],
        )?;
        total += i64::from(!existing);
        batch.indexed += 1;
    }
    txn.commit()?;
    Ok((Some((batch, rules)), stopped))
}

fn image_stream_with<E: ImageEncoder>(
    database: &Path,
    connect: impl FnOnce() -> Result<E>,
    after: Option<&str>,
    max: usize,
    stop: &AtomicBool,
    mut emit: impl FnMut(&ImageBatch) -> Result<()>,
) -> Result<()> {
    ensure!(
        (1..=MAX_BATCH).contains(&max),
        "image batch size must be 1 through {MAX_BATCH}"
    );
    let database = absolute(database)?;
    let reader = open_read(&database)?;
    let mut writer = None;
    let mut worker = None;
    let mut connect = Some(connect);
    let mut cursor = after.map(str::to_owned);
    let mut locked_rules = None;
    loop {
        if stop.load(Ordering::Acquire) {
            break;
        }
        let (step, stopped) = image_batch_step(
            &database,
            &reader,
            &mut writer,
            &mut connect,
            &mut worker,
            cursor.as_deref(),
            max,
            locked_rules.as_ref(),
            Some(stop),
            true,
        )?;
        let Some((batch, rules)) = step else {
            break;
        };
        if locked_rules.is_none() {
            locked_rules = Some(rules);
        }
        let done = stopped
            || batch.limited
            || batch.next_after.as_deref() == cursor.as_deref()
            || batch.next_after.is_none();
        emit(&batch)?;
        if done {
            break;
        }
        cursor = batch.next_after;
    }
    Ok(())
}

/// Called by the standard activation validator after current live metadata has matched.
pub(crate) fn stored_match(conn: &Connection, id: i64, path: &Path, stamp: &str) -> Result<bool> {
    if !supported_path(path) {
        return Ok(false);
    }
    let Some(rules) = Rules::read(conn)? else {
        return Ok(false);
    };
    if !rules.allows(path) {
        return Ok(false);
    }
    let stored: Option<String> = conn
        .query_row(
            "SELECT stamp FROM image_embedding WHERE id=?1 AND model=?2
             AND typeof(vector)='blob' AND length(vector) IN (?3/2,?3)",
            params![id, MODEL_ID, LEGACY_VECTOR_BYTES],
            |r| r.get(0),
        )
        .optional()?;
    Ok(stored
        .as_deref()
        .is_some_and(|stored| crate::index::stamp_matches(stored, stamp)))
}

pub struct ImageSearchSession<'a> {
    conn: Connection,
    model: &'a GemmaModel,
    projector: PathBuf,
    worker: Option<GemmaQuery>,
    matrix: MatrixCache<ImageRow>,
}

impl<'a> ImageSearchSession<'a> {
    pub fn index_stream(
        database: &Path,
        model: &GemmaModel,
        projector: &Path,
        after: Option<&str>,
        max: usize,
        stop: &AtomicBool,
        emit: impl FnMut(&ImageBatch) -> Result<()>,
    ) -> Result<()> {
        image_stream_with(
            database,
            || model.start_images(projector),
            after,
            max,
            stop,
            emit,
        )
    }

    pub fn open(database: &Path, model: &'a GemmaModel, projector: PathBuf) -> Result<Self> {
        Ok(Self {
            conn: open_read(database)?,
            model,
            projector,
            worker: None,
            matrix: MatrixCache::default(),
        })
    }

    pub fn search(&mut self, text: &str, limit: usize) -> Result<Vec<Hit>> {
        self.search_candidates(text, limit.min(20))
    }

    #[doc(hidden)]
    pub fn search_candidates(&mut self, text: &str, limit: usize) -> Result<Vec<Hit>> {
        let text = text.trim();
        if text.is_empty() || text.len() > 8192 || limit == 0 || !crate::query_allows_semantic(text)
        {
            return Ok(Vec::new());
        }
        let worker = match &mut self.worker {
            Some(worker) => worker,
            None => {
                // This cold-start probe only avoids launching an unused model.
                // Ranking rechecks scope and availability after inference.
                let Some(rules) = Rules::read(&self.conn)? else {
                    return Ok(Vec::new());
                };
                if count_images(&self.conn, &rules)? == 0 {
                    return Ok(Vec::new());
                }
                self.worker.insert(GemmaQuery::Worker(
                    self.model.start_images(&self.projector)?,
                ))
            }
        };
        let query = worker.encode(text)?;
        read_snapshot(&self.conn, |snapshot| {
            Ok(rank_images(
                self.matrix
                    .get_for_bucket(snapshot, "img_generation", load_images)?,
                &query,
                limit,
            ))
        })
    }
}

struct ImageRow {
    path: Box<str>,
    name: Box<str>,
    availability: Box<str>,
    stamp: Box<str>,
}

fn load_images(snapshot: &Connection) -> Result<Matrix<ImageRow>> {
    let mut matrix = Matrix::new(DIMENSIONS);
    let Some(rules) = Rules::read(snapshot)? else {
        return Ok(matrix);
    };
    let (lower, upper) = rules.bounds();
    let mut stmt = snapshot.prepare_cached(&format!(
        "SELECT i.path,i.display,i.availability,e.stamp,e.vector {IMAGE_LIVE}"
    ))?;
    let mut rows = stmt.query(params![MODEL_ID, lower, upper, LEGACY_VECTOR_BYTES])?;
    while let Some(row) = rows.next()? {
        let path = row.get_ref(0)?.as_str()?;
        if rules.allows(Path::new(path)) {
            matrix.push(
                ImageRow {
                    path: path.into(),
                    name: row.get_ref(1)?.as_str()?.into(),
                    availability: row.get_ref(2)?.as_str()?.into(),
                    stamp: row.get_ref(3)?.as_str()?.into(),
                },
                row.get_ref(4)?.as_blob()?,
            );
        }
    }
    Ok(matrix)
}

fn rank_images(matrix: &Matrix<ImageRow>, query: &[f32], limit: usize) -> Vec<Hit> {
    let scores: Vec<_> = matrix.scores(query).collect();
    let floor = adaptive_floor(&scores, MIN_COSINE, Z_THRESHOLD);
    let mut hits: Vec<_> = scores
        .into_iter()
        .zip(&matrix.rows)
        .filter(|(score, _)| score.is_finite() && f64::from(*score) >= floor)
        .collect();
    hits.sort_unstable_by(|a, b| b.0.total_cmp(&a.0).then_with(|| a.1.path.cmp(&b.1.path)));
    hits.into_iter()
        .filter_map(|(score, row)| {
            let live = local_stamp(Path::new(row.path.as_ref()), false)?;
            if !crate::index::stamp_matches(row.stamp.as_ref(), &live) {
                return None;
            }
            Some(Hit {
                path: row.path.to_string(),
                name: row.name.to_string(),
                kind: "file".into(),
                availability: row.availability.to_string(),
                matched_by: "image_embedding".into(),
                snippet: None,
                document_stamp: Some(live),
                pdf_page: None,
                score: Some(score.into()),
            })
        })
        .take(limit)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diagnose::snapshot_tests::{start_benign_writes, stop_benign_writes};
    use std::fs;

    fn query_vector() -> Vec<f32> {
        let mut query = vec![0.0; DIMENSIONS];
        query[0] = 1.0;
        query
    }

    #[test]
    fn image_cache_ranks_mixed_formats_and_refreshes_when_scope_changes() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-image-matrix-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let images = root.join("images");
        fs::create_dir_all(&images).unwrap();
        let paths: Vec<_> = [
            "a.HEIC",
            "b.heif",
            "c.webp",
            "d.png",
            "e.jpg",
            "f.jpeg",
            "g.webp",
            "h.png",
            "malformed.webp",
        ]
        .into_iter()
        .map(|name| {
            let path = images.join(name);
            fs::write(&path, "index entry for a precomputed vector").unwrap();
            path
        })
        .collect();
        let database = root.join("index.db");
        crate::scan(
            &database,
            &Scope {
                roots: vec![images.clone()],
                ..Scope::default()
            },
        )
        .unwrap();
        image_scope(&database, Some(&images)).unwrap();
        let writer = Connection::open(&database).unwrap();
        let store = |i: usize| {
            let mut v = vec![0.0_f32; DIMENSIONS];
            v[0] = if i == 0 { 0.9375 } else { 0.6875 };
            v[1] = (1.0 - v[0].powi(2)).sqrt();
            let bytes = match i {
                8 => vec![0_u8],
                i if i.is_multiple_of(2) => pack(&v),
                _ => v.into_iter().flat_map(f32::to_le_bytes).collect(),
            };
            let path = &paths[i];
            let stamp = local_stamp(path, false).unwrap();
            let id: i64 = writer
                .query_row(
                    "SELECT id FROM item WHERE path=?1",
                    [path.to_str().unwrap()],
                    |r| r.get(0),
                )
                .unwrap();
            writer
                .execute(
                    "INSERT INTO image_embedding VALUES (?1,?2,?3,?4)",
                    params![id, MODEL_ID, stamp, bytes],
                )
                .unwrap();
            assert_eq!(stored_match(&writer, id, path, &stamp).unwrap(), i != 8);
        };
        for i in [0, 1, 2, 8] {
            store(i);
        }
        assert_eq!(image_status(&database).unwrap().vectors, 3);
        let model = GemmaModel::installed(Some(&root)).unwrap();
        let mut session =
            ImageSearchSession::open(&database, &model, "unused-projector".into()).unwrap();
        session.worker = Some(GemmaQuery::Fixture(Box::new(query_vector)));
        let lookup = |session: &mut ImageSearchSession<'_>| {
            session
                .search("image fixture", 20)
                .unwrap()
                .into_iter()
                .map(|hit| hit.name)
                .collect::<Vec<_>>()
        };
        assert_eq!(lookup(&mut session), ["a.HEIC", "b.heif", "c.webp"]);
        read_snapshot(&session.conn, |snapshot| {
            session
                .matrix
                .get_for_bucket(snapshot, "img_generation", |_| {
                    panic!("unchanged image scope reloaded the matrix")
                })?;
            Ok(())
        })
        .unwrap();
        for i in 3..8 {
            store(i);
        }
        assert_eq!(lookup(&mut session), ["a.HEIC"]);
        let batch = image_batch(
            &database,
            &GemmaModel::installed(None).unwrap(),
            Path::new("unused-projector"),
            None,
            16,
        )
        .unwrap();
        assert_eq!((batch.processed, batch.reused, batch.skipped), (9, 8, 1));
        image_scope(&database, None).unwrap();
        assert!(lookup(&mut session).is_empty());
        drop(session);
        drop(writer);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn image_search_survives_benign_writes_and_honors_revocations_during_inference() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-image-snapshot-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let images = root.join("images");
        fs::create_dir_all(&images).unwrap();
        let path = images.join("sample.png");
        fs::write(&path, "image fixture with a precomputed vector").unwrap();
        let database = root.join("index.db");
        crate::index::scan(
            &database,
            &Scope {
                roots: vec![images.clone()],
                ..Scope::default()
            },
        )
        .unwrap();
        image_scope(&database, Some(&images)).unwrap();
        let writer = Connection::open(&database).unwrap();
        let vector = pack(&query_vector());
        assert_eq!(
            writer
                .execute(
                    "INSERT INTO image_embedding SELECT id,?1,?2,?3 FROM item WHERE path=?4",
                    params![
                        MODEL_ID,
                        local_stamp(&path, false).unwrap(),
                        vector,
                        path.to_str().unwrap()
                    ],
                )
                .unwrap(),
            1
        );
        let model = GemmaModel::installed(Some(&root)).unwrap();
        let mut session =
            ImageSearchSession::open(&database, &model, "unused-projector".into()).unwrap();
        let text = "image fixture";
        let assert_visible = |session: &mut ImageSearchSession<'_>| {
            session.worker = Some(GemmaQuery::Fixture(Box::new(query_vector)));
            let hits = session.search(text, 20).unwrap();
            assert_eq!(hits.len(), 1);
            assert_eq!(hits[0].path, path.to_str().unwrap());
        };
        assert_visible(&mut session);
        start_benign_writes(&session.conn, &database);
        for _ in 0..8 {
            let hits = session.search_candidates(text, 20).unwrap();
            assert_eq!(hits.len(), 1);
            assert_eq!(hits[0].path, path.to_str().unwrap());
        }
        assert!(stop_benign_writes(&session.conn) >= 8);

        for update in [
            // Leave the item and vector in place when changing only policy.
            "UPDATE info SET value=json_set(value,'$.deny',json_array((SELECT path FROM item WHERE display='sample.png'))) WHERE key='scope'",
            // Keep the vector to make sure availability is independently checked.
            "DROP TRIGGER image_entry_moved; UPDATE item SET availability='unverified' WHERE display='sample.png'",
            "UPDATE image_scope SET root=NULL,epoch=epoch+1",
        ] {
            assert_visible(&mut session);
            let database = database.clone();
            session.worker = Some(GemmaQuery::Fixture(Box::new(move || {
                // Commit from a separate connection while search is encoding,
                // before its ranking snapshot can be pinned.
                Connection::open(&database)
                    .unwrap()
                    .execute_batch(update)
                    .unwrap();
                query_vector()
            })));
            assert!(
                session.search_candidates(text, 20).unwrap().is_empty(),
                "{update}"
            );
            writer.execute_batch("UPDATE info SET value=json_set(value,'$.deny',json('[]')) WHERE key='scope'; UPDATE item SET availability='local' WHERE display='sample.png'").unwrap();
        }
        drop(session);
        drop(writer);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn resident_cloud_images_index_search_and_match_legacy_seven_field_stamps() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-image-cloud-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let cloud_images = root.join("Library/CloudStorage/OneDrive-Test/Photos");
        fs::create_dir_all(&cloud_images).unwrap();
        let path = cloud_images.join("resident.png");
        fs::write(&path, "resident cloud image fixture").unwrap();
        let database = root.join("index.db");
        crate::index::scan(
            &database,
            &Scope {
                roots: vec![cloud_images.clone()],
                ..Scope::default()
            },
        )
        .unwrap();
        let status = image_scope(&database, Some(&cloud_images)).unwrap();
        assert_eq!(status.root.as_deref(), cloud_images.to_str());

        let writer = Connection::open(&database).unwrap();
        let (id, availability): (i64, String) = writer
            .query_row(
                "SELECT id,availability FROM item WHERE path=?1",
                [path.to_str().unwrap()],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(availability, "provider_metadata_only");

        let live_stamp = local_stamp(&path, false).unwrap();
        assert_eq!(live_stamp.split(':').count(), 5);
        let legacy_stamp = format!("{live_stamp}:123456:789");
        let vector = pack(&query_vector());
        writer
            .execute(
                "INSERT INTO image_embedding VALUES (?1,?2,?3,?4)",
                params![id, MODEL_ID, legacy_stamp, vector],
            )
            .unwrap();
        assert!(stored_match(&writer, id, &path, &live_stamp).unwrap());
        assert_eq!(image_status(&database).unwrap().vectors, 1);

        let batch = image_batch(
            &database,
            &GemmaModel::installed(None).unwrap(),
            Path::new("unused-projector"),
            None,
            16,
        )
        .unwrap();
        assert_eq!((batch.processed, batch.reused, batch.skipped), (1, 1, 0));

        let model = GemmaModel::installed(Some(&root)).unwrap();
        let mut session =
            ImageSearchSession::open(&database, &model, "unused-projector".into()).unwrap();
        session.worker = Some(GemmaQuery::Fixture(Box::new(query_vector)));
        let hits = session.search("resident photo", 10).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].path, path.to_str().unwrap());
        assert_eq!(hits[0].availability, "provider_metadata_only");
        assert_eq!(hits[0].document_stamp.as_deref(), Some(live_stamp.as_str()));

        drop(session);
        drop(writer);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn image_stream_boots_worker_once_and_stops_on_completion_or_signal() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-image-stream-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let images = root.join("images");
        fs::create_dir_all(&images).unwrap();
        // Minimal valid 1x1 PNG so thumbnail() succeeds without CoreGraphics errors.
        let png: &[u8] = &[
            0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, b'I', b'H',
            b'D', b'R', 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00,
            0x00, 0x90, 0x77, 0x53, 0xde, 0x00, 0x00, 0x00, 0x0c, b'I', b'D', b'A', b'T', 0x08,
            0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00, 0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xdd, 0x8d,
            0xb0, 0x00, 0x00, 0x00, 0x00, b'I', b'E', b'N', b'D', 0xae, 0x42, 0x60, 0x82,
        ];
        for i in 0..5 {
            fs::write(images.join(format!("img-{i}.png")), png).unwrap();
        }
        let database = root.join("index.db");
        crate::index::scan(
            &database,
            &Scope {
                roots: vec![images.clone()],
                ..Scope::default()
            },
        )
        .unwrap();
        image_scope(&database, Some(&images)).unwrap();

        struct MockImageEncoder {
            on_encode: Box<dyn FnMut() -> Result<Vec<f32>>>,
        }
        impl ImageEncoder for MockImageEncoder {
            fn encode_image_bytes(&mut self, _: &[u8]) -> Result<Vec<f32>> {
                (self.on_encode)()
            }
        }

        let mut connect_count = 0usize;
        let stop = AtomicBool::new(false);
        let mut batches = Vec::new();
        image_stream_with(
            &database,
            || {
                connect_count += 1;
                Ok(MockImageEncoder {
                    on_encode: Box::new(|| Ok(query_vector())),
                })
            },
            None,
            2,
            &stop,
            |batch| {
                batches.push((
                    batch.processed,
                    batch.indexed,
                    batch.reused,
                    batch.next_after.is_some(),
                ));
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(connect_count, 1);
        assert_eq!(
            batches,
            [(2, 2, 0, true), (2, 2, 0, true), (1, 1, 0, false)]
        );
        assert_eq!(image_status(&database).unwrap().vectors, 5);

        // Cached re-run skips launching the worker completely.
        let mut cached_connects = 0usize;
        let mut cached_batches = Vec::new();
        image_stream_with(
            &database,
            || {
                cached_connects += 1;
                Ok(MockImageEncoder {
                    on_encode: Box::new(|| Ok(query_vector())),
                })
            },
            None,
            2,
            &stop,
            |batch| {
                cached_batches.push((
                    batch.processed,
                    batch.indexed,
                    batch.reused,
                    batch.next_after.is_some(),
                ));
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(cached_connects, 0);
        assert_eq!(
            cached_batches,
            [(2, 0, 2, true), (2, 0, 2, true), (1, 0, 1, false)]
        );

        // Clean stop signal mid-batch yields partial progress and exits cleanly.
        let writer = Connection::open(&database).unwrap();
        writer.execute("DELETE FROM image_embedding", []).unwrap();
        drop(writer);
        let stop_flag = std::sync::Arc::new(AtomicBool::new(false));
        let trigger = stop_flag.clone();
        let mut stopped_batches = Vec::new();
        image_stream_with(
            &database,
            || {
                Ok(MockImageEncoder {
                    on_encode: Box::new(move || {
                        trigger.store(true, Ordering::Release);
                        Ok(query_vector())
                    }),
                })
            },
            None,
            2,
            &stop_flag,
            |batch| {
                stopped_batches.push((batch.processed, batch.indexed, batch.next_after.is_some()));
                Ok(())
            },
        )
        .unwrap();
        assert_eq!(stopped_batches, [(1, 1, true)]);
        assert_eq!(image_status(&database).unwrap().vectors, 1);

        fs::remove_dir_all(root).unwrap();
    }
}
