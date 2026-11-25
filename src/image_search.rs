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
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::Serialize;
use std::path::{Path, PathBuf};

pub const MODEL_ID: &str = "gemma2/image/imageio512-v1/q8_0/b11457/retrieval/768/l2/0531309472a6bc6f4b146c3736eee7795ec9db1903c25490d3c937490cef6dd8";
const MAX_VECTORS: i64 = 4096;
const MAX_BATCH: usize = 16;
// A minimum cosine for this exact model, not an estimate of correctness.
const MIN_COSINE: f32 = 0.65;
const Z_THRESHOLD: f64 = 1.0;
const LEGACY_VECTOR_BYTES: i64 = (DIMENSIONS * 4) as i64;
const IMAGE_LIVE: &str = "FROM image_embedding e JOIN item i USING(id)
    WHERE e.model=?1 AND i.path>=?2 AND i.path<?3 AND i.kind='file' AND i.availability='local'
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
    let snapshot = reader.unchecked_transaction()?;
    let rules = Rules::read(&snapshot)?.context("choose a folder with image-scope first")?;
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
               AND i.kind='file' AND i.availability='local'
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
    let mut batch = ImageBatch {
        model_id: MODEL_ID,
        processed: rows.len().min(max),
        indexed: 0,
        reused: 0,
        skipped: 0,
        limited: false,
        next_after: (rows.len() > max).then(|| rows[max - 1].1.clone()),
    };
    let mut worker = None;
    let mut encoded = Vec::new();
    for (id, path, prior, occupied) in rows.into_iter().take(max) {
        ensure!(
            Rules::read(&reader)?.as_ref() == Some(&rules),
            "image or filename scope changed; retry the batch"
        );
        let source = Path::new(&path);
        let stamp = rules
            .allows(source)
            .then(|| local_stamp(source, false))
            .flatten();
        let Some(stamp) = stamp else {
            batch.skipped += 1;
            continue;
        };
        if prior.as_deref() == Some(&stamp) {
            batch.reused += 1;
            continue;
        }
        if !occupied && available <= 0 {
            batch.limited = true;
            batch.skipped += 1;
            continue;
        }
        let Ok(bytes) = platform::read_local_checked(source, MAX_FILE_BYTES, Some(&stamp)) else {
            batch.skipped += 1;
            continue;
        };
        let Some(bytes) = thumbnail(&bytes) else {
            batch.skipped += 1;
            continue;
        };
        let worker = match &mut worker {
            Some(worker) => worker,
            None => worker.insert(model.start_images(projector)?),
        };
        let vector = worker.encode_image(&bytes)?;
        available -= i64::from(!occupied);
        encoded.push((id, path, stamp, pack(&vector)));
    }
    if encoded.is_empty() {
        return Ok(batch);
    }

    let (mut conn, _lease) = open_write(&database, false)?;
    let txn = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    ensure!(
        Rules::read(&txn)?.as_ref() == Some(&rules),
        "image or filename scope changed; retry the batch"
    );
    let mut total: i64 = txn.query_row("SELECT count(*) FROM image_embedding", [], |r| r.get(0))?;
    for (id, path, stamp, packed) in encoded {
        let still_indexed: bool = txn.query_row(
            "SELECT EXISTS(SELECT 1 FROM item WHERE id=?1 AND path=?2 AND kind='file' AND availability='local')",
            params![id, path], |r| r.get(0),
        )?;
        if !still_indexed || local_stamp(Path::new(&path), false).as_deref() != Some(&stamp) {
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
    Ok(batch)
}

/// Called by the standard activation validator after current live metadata has matched.
pub(crate) fn stored_match(conn: &Connection, id: i64, path: &Path, stamp: &str) -> Result<bool> {
    if !supported_path(path) {
        return Ok(false);
    }
    let Some(rules) = Rules::read(conn)? else {
        return Ok(false);
    };
    Ok(rules.allows(path)
        && conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM image_embedding WHERE id=?1 AND model=?2 AND stamp=?3
             AND typeof(vector)='blob' AND length(vector) IN (?4/2,?4))",
            params![id, MODEL_ID, stamp, LEGACY_VECTOR_BYTES],
            |r| r.get(0),
        )?)
}

pub struct ImageSearchSession<'a> {
    conn: Connection,
    model: &'a GemmaModel,
    projector: PathBuf,
    worker: Option<GemmaQuery>,
    matrix: MatrixCache<ImageRow>,
}

impl<'a> ImageSearchSession<'a> {
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
                self.matrix.get(snapshot, load_images)?,
                &query,
                limit,
            ))
        })
    }
}

struct ImageRow {
    path: Box<str>,
    name: Box<str>,
    stamp: Box<str>,
}

fn load_images(snapshot: &Connection) -> Result<Matrix<ImageRow>> {
    let mut matrix = Matrix::new(DIMENSIONS);
    let Some(rules) = Rules::read(snapshot)? else {
        return Ok(matrix);
    };
    let (lower, upper) = rules.bounds();
    let mut stmt = snapshot.prepare_cached(&format!(
        "SELECT i.path,i.display,e.stamp,e.vector {IMAGE_LIVE}"
    ))?;
    let mut rows = stmt.query(params![MODEL_ID, lower, upper, LEGACY_VECTOR_BYTES])?;
    while let Some(row) = rows.next()? {
        let path = row.get_ref(0)?.as_str()?;
        if rules.allows(Path::new(path)) {
            matrix.push(
                ImageRow {
                    path: path.into(),
                    name: row.get_ref(1)?.as_str()?.into(),
                    stamp: row.get_ref(2)?.as_str()?.into(),
                },
                row.get_ref(3)?.as_blob()?,
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
            if local_stamp(Path::new(row.path.as_ref()), false).as_deref()
                != Some(row.stamp.as_ref())
            {
                return None;
            }
            Some(Hit {
                path: row.path.to_string(),
                name: row.name.to_string(),
                kind: "file".into(),
                availability: "local".into(),
                matched_by: "image_embedding".into(),
                snippet: None,
                document_stamp: Some(row.stamp.to_string()),
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
            session.matrix.get(snapshot, |_| {
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
}
