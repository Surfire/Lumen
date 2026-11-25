use crate::{
    GemmaModel, Hit, Scope, absolute,
    content::has_table,
    diagnose::local_stamp,
    gemma::{DIMENSIONS, GemmaWorker},
    image_decode::thumbnail,
    model::Role,
    open_read, open_write, platform, saved_index_scope,
};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::Serialize;
use std::path::{Path, PathBuf};

pub const MODEL_ID: &str = "gemma2/image/imageio512-v1/q8_0/b11457/retrieval/768/l2/0531309472a6bc6f4b146c3736eee7795ec9db1903c25490d3c937490cef6dd8";
const MAX_VECTORS: i64 = 4096;
const MAX_BATCH: usize = 16;
const MAX_FILE_BYTES: u64 = 12 * 1024 * 1024;
// A candidate floor for this exact model, not an estimate of correctness.
const CANDIDATE_FLOOR: f32 = 0.65;
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
        path != Path::new(&self.root) && path.starts_with(&self.root) && named_in(&self.names, path)
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
    let Some(rules) = Rules::read(&conn)? else {
        return Ok(ImageScopeStatus {
            root: None,
            vectors: 0,
        });
    };
    let vectors = conn.query_row(
        "SELECT count(*) FROM image_embedding WHERE model=?1",
        [MODEL_ID],
        |row| row.get(0),
    )?;
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
    let vectors = txn.query_row(
        "SELECT count(*) FROM image_embedding WHERE model=?1",
        [MODEL_ID],
        |r| r.get(0),
    )?;
    txn.commit()?;
    Ok(ImageScopeStatus { root, vectors })
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
            "SELECT i.id,i.path,CASE WHEN e.model=?4 THEN e.stamp END,e.id IS NOT NULL
             FROM item i LEFT JOIN image_embedding e ON i.id=e.id
             WHERE i.path>=?1 AND i.path<?2 AND i.path>?3
               AND i.kind='file' AND i.availability='local'
               AND (substr(lower(i.path),-4) IN ('.png','.jpg') OR substr(lower(i.path),-5)='.jpeg')
             ORDER BY i.path LIMIT ?5",
        )?;
        stmt.query_map(
            params![lower, upper, after, MODEL_ID, max as i64 + 1],
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
        let packed = vector
            .iter()
            .flat_map(|value| value.to_le_bytes())
            .collect::<Vec<_>>();
        encoded.push((id, path, stamp, packed));
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
    if !path.extension().is_some_and(|ext| {
        ["png", "jpg", "jpeg"]
            .iter()
            .any(|kind| ext.eq_ignore_ascii_case(kind))
    }) {
        return Ok(false);
    }
    let Some(rules) = Rules::read(conn)? else {
        return Ok(false);
    };
    Ok(rules.allows(path)
        && conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM image_embedding WHERE id=?1 AND model=?2 AND stamp=?3)",
            params![id, MODEL_ID, stamp],
            |r| r.get(0),
        )?)
}

pub struct ImageSearchSession<'a> {
    conn: Connection,
    model: &'a GemmaModel,
    projector: PathBuf,
    worker: Option<GemmaWorker>,
}

impl<'a> ImageSearchSession<'a> {
    pub fn open(database: &Path, model: &'a GemmaModel, projector: PathBuf) -> Result<Self> {
        Ok(Self {
            conn: open_read(database)?,
            model,
            projector,
            worker: None,
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
        let Some(_) = Rules::read(&self.conn)? else {
            return Ok(Vec::new());
        };
        let present: bool = self.conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM image_embedding WHERE model=?1)",
            [MODEL_ID],
            |r| r.get(0),
        )?;
        if !present {
            return Ok(Vec::new());
        }
        let worker = match &mut self.worker {
            Some(worker) => worker,
            None => self
                .worker
                .insert(self.model.start_images(&self.projector)?),
        };
        let query = worker.encode(Role::Query, text)?;
        Ok(crate::diagnose::read_snapshot(&self.conn, |snapshot| {
            search_in_snapshot(snapshot, &query, limit)
        })?
        .unwrap_or_default())
    }
}

fn search_in_snapshot(snapshot: &Connection, query: &[f32], limit: usize) -> Result<Vec<Hit>> {
    let Some(rules) = Rules::read(snapshot)? else {
        return Ok(Vec::new());
    };
    let (lower, upper) = rules.bounds();
    let mut hits = Vec::new();
    {
        let mut stmt = snapshot.prepare_cached(
                "SELECT i.path,i.display,e.stamp,e.vector FROM image_embedding e JOIN item i USING(id)
                 WHERE e.model=?1 AND i.path>=?2 AND i.path<?3 AND i.kind='file' AND i.availability='local'",
            )?;
        let mut rows = stmt.query(params![MODEL_ID, lower, upper])?;
        while let Some(row) = rows.next()? {
            let path: String = row.get(0)?;
            if !rules.allows(Path::new(&path)) {
                continue;
            }
            let vector = row.get_ref(3)?.as_blob()?;
            if vector.len() != DIMENSIONS * 4 {
                continue;
            }
            let score = vector
                .chunks_exact(4)
                .zip(query)
                .map(|(bytes, q)| {
                    f32::from_le_bytes(bytes.try_into().expect("four vector bytes")) * q
                })
                .sum::<f32>();
            if score.is_finite() && score >= CANDIDATE_FLOOR {
                hits.push((
                    score,
                    path,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ));
            }
        }
    }
    hits.sort_unstable_by(|a, b| b.0.total_cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    let hits = hits
        .into_iter()
        .filter_map(|(score, path, name, stamp)| {
            if local_stamp(Path::new(&path), false).as_deref() != Some(&stamp) {
                return None;
            }
            Some(Hit {
                path,
                name,
                kind: "file".into(),
                availability: "local".into(),
                matched_by: "image_embedding".into(),
                snippet: None,
                document_stamp: Some(stamp),
                pdf_page: None,
                score: Some(score.into()),
            })
        })
        .take(limit)
        .collect();
    Ok(hits)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn image_snapshot_retries_and_observes_latest_catalog() {
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
        let mut query = vec![0.0_f32; DIMENSIONS];
        query[0] = 1.0;
        let vector: Vec<u8> = query.iter().flat_map(|value| value.to_le_bytes()).collect();
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
            .unwrap();
        let reader = open_read(&database).unwrap();
        let mut attempts = 0;
        let hits = crate::diagnose::read_snapshot(&reader, |snapshot| {
            attempts += 1;
            let hits = search_in_snapshot(snapshot, &query, 20)?;
            if attempts < 3 {
                writer.execute(
                    "UPDATE item SET display=?1 WHERE path=?2",
                    params![format!("latest-{attempts}"), path.to_str().unwrap()],
                )?;
            }
            Ok(hits)
        })
        .unwrap()
        .unwrap();
        assert_eq!(attempts, 3);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].name, "latest-2");
        assert_eq!(hits[0].path, path.to_str().unwrap());
        drop(reader);
        drop(writer);
        fs::remove_dir_all(root).unwrap();
    }
}
