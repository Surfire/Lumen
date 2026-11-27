use crate::{
    ContentCategory, GemmaModel, Hit, Scope, absolute,
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
const MIN_IMAGE_VECTOR_BYTES: u64 = 32 * 1024 * 1024;
const MAX_IMAGE_VECTOR_BYTES: u64 = 512 * 1024 * 1024;
const MAX_BATCH: usize = 16;
// A minimum cosine for this exact model, not an estimate of correctness.
const MIN_COSINE: f32 = 0.65;
const Z_THRESHOLD: f64 = 1.0;
const LEGACY_VECTOR_BYTES: i64 = (DIMENSIONS * 4) as i64;
const IMAGE_ITEM_WHERE: &str = "i.kind='file' AND i.availability IN ('local','provider_metadata_only') AND (substr(lower(i.path),-4) IN ('.png','.jpg') OR substr(lower(i.path),-5) IN ('.jpeg','.heic','.heif','.webp'))";
#[cfg(test)]
pub(crate) const CREATE_IMAGE_MTIME_INDEX: &str = "CREATE INDEX IF NOT EXISTS item_image_mtime ON item(mtime DESC, id DESC, path, kind, availability) WHERE kind='file' AND availability IN ('local','provider_metadata_only') AND (substr(lower(path),-4) IN ('.png','.jpg') OR substr(lower(path),-5) IN ('.jpeg','.heic','.heif','.webp'));";
const IMAGE_LIVE: &str = "FROM image_embedding e JOIN item i USING(id)
    WHERE e.model=?1 AND i.path>=?2 AND i.path<?3 AND i.kind='file'
    AND i.availability IN ('local','provider_metadata_only')
    AND typeof(e.vector)='blob' AND length(e.vector) IN (?4/2,?4)";
pub(crate) const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS image_embedding(
        id INTEGER PRIMARY KEY, model TEXT NOT NULL, stamp TEXT NOT NULL, vector BLOB NOT NULL
    );
    CREATE TABLE IF NOT EXISTS image_skip(
        id INTEGER PRIMARY KEY, model TEXT NOT NULL, stamp TEXT NOT NULL
    );
    CREATE TRIGGER IF NOT EXISTS image_entry_deleted AFTER DELETE ON item
    BEGIN DELETE FROM image_embedding WHERE id=old.id; END;
    CREATE TRIGGER IF NOT EXISTS image_entry_moved AFTER UPDATE OF path, kind, availability ON item
    WHEN NEW.path != OLD.path OR NEW.kind != OLD.kind OR NEW.availability != OLD.availability
    BEGIN DELETE FROM image_embedding WHERE id=old.id; END;
    CREATE TRIGGER IF NOT EXISTS image_skip_deleted AFTER DELETE ON item
    BEGIN DELETE FROM image_skip WHERE id=old.id; END;
    CREATE TRIGGER IF NOT EXISTS image_skip_moved AFTER UPDATE OF path, kind, availability, mtime ON item
    WHEN NEW.path != OLD.path OR NEW.kind != OLD.kind OR NEW.availability != OLD.availability OR NEW.mtime != OLD.mtime
    BEGIN DELETE FROM image_skip WHERE id=old.id; END;
    CREATE INDEX IF NOT EXISTS item_image_mtime ON item(mtime DESC, id DESC, path, kind, availability) WHERE kind='file' AND availability IN ('local','provider_metadata_only') AND (substr(lower(path),-4) IN ('.png','.jpg') OR substr(lower(path),-5) IN ('.jpeg','.heic','.heif','.webp'));
";

pub(crate) fn image_limit_for_memory(ram_bytes: u64) -> i64 {
    let budget = (ram_bytes / 100).clamp(MIN_IMAGE_VECTOR_BYTES, MAX_IMAGE_VECTOR_BYTES);
    (budget / ((DIMENSIONS as u64) * 2)) as i64
}

pub fn image_limit() -> i64 {
    image_limit_for_memory(crate::platform::physical_memory_bytes())
}

fn has_mtime_index(conn: &Connection) -> Result<bool> {
    Ok(conn.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='index' AND name='item_image_mtime')",
        [],
        |r| r.get(0),
    )?)
}

pub(crate) fn ensure_schema(conn: &Connection) -> Result<()> {
    if !has_table(conn, "image_embedding")?
        || !has_table(conn, "image_skip")?
        || !has_mtime_index(conn)?
    {
        conn.execute_batch(SCHEMA)?;
    }
    Ok(())
}

/// Image rules derived from the one saved content scope: `content_roots`
/// gated by `content_filter.enable_images`. There is no separate image list.
#[derive(Debug, PartialEq, Eq)]
struct Rules {
    /// Non-nested UTF-8 content roots, ordered by their path range.
    roots: Vec<PathBuf>,
    names: Scope,
}

impl Rules {
    fn read(conn: &Connection) -> Result<Option<Self>> {
        if !has_table(conn, "image_embedding")? {
            return Ok(None);
        }
        Ok(saved_index_scope(conn)?.and_then(Self::from_scope))
    }

    fn from_scope(names: Scope) -> Option<Self> {
        if !names.documents || !names.content_filter.enable_images {
            return None;
        }
        let candidates: Vec<&PathBuf> = names
            .content_roots
            .iter()
            .flatten()
            .filter(|root| root.as_path() != Path::new("/") && root.to_str().is_some())
            .collect();
        let mut roots: Vec<PathBuf> = candidates
            .iter()
            .filter(|root| {
                !candidates
                    .iter()
                    .any(|other| other != *root && root.starts_with(other))
            })
            .map(|root| (*root).clone())
            .collect();
        roots.sort_by_key(|root| format!("{}/", root.display()));
        roots.dedup();
        (!roots.is_empty()).then_some(Self { roots, names })
    }

    fn allows(&self, path: &Path) -> bool {
        supported_path(path)
            && self
                .roots
                .iter()
                .any(|root| path.starts_with(root) && path != root)
            && named_in(&self.names, path)
            && !self.names.content_filter.excludes(path, &self.roots)
            && self.names.content_filter.category(path) == Some(ContentCategory::Image)
    }

    /// Disjoint `[root/, root0)` ranges in ascending path order.
    fn bounds(&self) -> impl Iterator<Item = (String, String)> + '_ {
        self.roots.iter().filter_map(|root| {
            let root = root.to_str()?;
            Some((format!("{root}/"), format!("{root}0")))
        })
    }

    fn strings(&self) -> Vec<String> {
        self.roots
            .iter()
            .filter_map(|root| root.to_str().map(str::to_owned))
            .collect()
    }
}

/// Add `root` to the explicit content roots unless already covered. A legacy
/// scope that indexed documents everywhere (`content_roots` unset) first keeps
/// that coverage as explicit roots, so adding a folder never narrows it.
fn add_content_root(scope: &mut Scope, root: PathBuf) {
    if scope.content_roots.is_none() && scope.documents {
        let mut seeded: Vec<PathBuf> = scope
            .roots
            .iter()
            .filter(|path| path.as_path() != Path::new("/"))
            .cloned()
            .collect();
        if scope.roots.is_empty() || scope.roots.iter().any(|path| path == Path::new("/")) {
            seeded.extend(
                scope
                    .allow
                    .iter()
                    .filter(|path| path.as_path() != Path::new("/"))
                    .cloned(),
            );
        }
        scope.content_roots = Some(seeded);
    }
    let roots = scope.content_roots.get_or_insert_with(Vec::new);
    if !roots.iter().any(|existing| root.starts_with(existing)) {
        roots.push(root);
    }
    scope.documents = true;
    scope.content_filter.enable_images = true;
}

fn named_in(scope: &Scope, path: &Path) -> bool {
    !crate::external::is_external(path)
        && scope.roots.iter().any(|root| path.starts_with(root))
        && scope.allows(path)
}

/// One-time migration of the retired `image_scope` table: its folder joins
/// `content_roots` and the legacy row is cleared, leaving one source of truth.
pub(crate) fn migrate_legacy_scope(conn: &mut Connection) -> Result<()> {
    const LEGACY: &str = "SELECT root FROM image_scope WHERE id=1 AND root IS NOT NULL";
    if !has_table(conn, "image_scope")?
        || conn
            .query_row(LEGACY, [], |r| r.get::<_, String>(0))
            .optional()?
            .is_none()
    {
        return Ok(());
    }
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let Some(root) = tx
        .query_row(LEGACY, [], |r| r.get::<_, String>(0))
        .optional()?
    else {
        return Ok(());
    };
    if let Some(mut scope) = saved_index_scope(&tx)? {
        add_content_root(&mut scope, PathBuf::from(root));
        tx.execute(
            "UPDATE info SET value=?1 WHERE key='scope'",
            [serde_json::to_string(&scope)?],
        )?;
        // Force the next scope pass to seed content jobs for the merged folder.
        tx.execute("DELETE FROM info WHERE key='cloud_content_policy_v1'", [])?;
    }
    tx.execute("UPDATE image_scope SET root=NULL,epoch=epoch+1", [])?;
    tx.commit()?;
    Ok(())
}

/// Drop image vectors the given scope no longer covers (inside the caller's
/// scope transaction).
pub(crate) fn prune(conn: &Connection, scope: &Scope) -> Result<()> {
    if !has_table(conn, "image_embedding")? {
        return Ok(());
    }
    let rules = Rules::from_scope(scope.clone());
    let doomed: Vec<i64> = {
        let mut stmt =
            conn.prepare("SELECT e.id,i.path FROM image_embedding e LEFT JOIN item i USING(id)")?;
        let mut rows = stmt.query([])?;
        let mut doomed = Vec::new();
        while let Some(row) = rows.next()? {
            let path: Option<String> = row.get(1)?;
            if !path.is_some_and(|path| rules.as_ref().is_some_and(|r| r.allows(Path::new(&path))))
            {
                doomed.push(row.get(0)?);
            }
        }
        doomed
    };
    let mut delete = conn.prepare_cached("DELETE FROM image_embedding WHERE id=?1")?;
    for id in doomed {
        delete.execute([id])?;
    }
    Ok(())
}

#[derive(Serialize)]
pub struct ImageScopeStatus {
    root: Option<String>,
    roots: Vec<String>,
    vectors: i64,
}

/// Inspect the image-enabled content folders and stored vector count without changing the database.
pub fn image_status(database: &Path) -> Result<ImageScopeStatus> {
    let conn = open_read(database)?;
    let snapshot = conn.unchecked_transaction()?;
    let Some(rules) = Rules::read(&snapshot)? else {
        return Ok(ImageScopeStatus {
            root: None,
            roots: Vec::new(),
            vectors: 0,
        });
    };
    let vectors = count_images(&snapshot, &rules)?;
    let roots = rules.strings();
    Ok(ImageScopeStatus {
        root: roots.first().cloned(),
        roots,
        vectors,
    })
}

/// Compatibility adapter for `image-scope`: add a folder to `content_roots`
/// with images enabled, or turn image vectors off. No file bytes are read.
pub fn image_scope(database: &Path, root: Option<&Path>) -> Result<ImageScopeStatus> {
    let database = absolute(database)?;
    let requested = root
        .map(|path| -> Result<PathBuf> {
            #[cfg(target_os = "macos")]
            let _io = platform::NoMaterialization::enter()?;
            let names =
                saved_index_scope(&open_read(&database)?)?.context("no filename index scope")?;
            let path = platform::filesystem_spelling(&absolute(path)?);
            ensure!(
                path != Path::new("/")
                    && named_in(&names, &path)
                    && local_stamp(&path, true).is_some(),
                "choose a readable local image folder within the saved filename scope"
            );
            ensure!(
                path.to_str().is_some(),
                "image folder path is not valid UTF-8"
            );
            Ok(path)
        })
        .transpose()?;
    crate::content::update_scope(&database, |scope| {
        match &requested {
            Some(path) => add_content_root(scope, path.clone()),
            None => scope.content_filter.enable_images = false,
        }
        Ok(())
    })?;
    let mut status = image_status(&database)?;
    if let Some(path) = requested {
        status.root = path.to_str().map(str::to_owned);
    }
    Ok(status)
}

fn count_images(conn: &Connection, rules: &Rules) -> Result<i64> {
    let mut stmt = conn.prepare_cached(&format!("SELECT i.path {IMAGE_LIVE}"))?;
    let mut count = 0;
    for (lower, upper) in rules.bounds() {
        let mut rows = stmt.query(params![MODEL_ID, lower, upper, LEGACY_VECTOR_BYTES])?;
        while let Some(row) = rows.next()? {
            count += i64::from(rules.allows(Path::new(row.get_ref(0)?.as_str()?)));
        }
    }
    Ok(count)
}

#[derive(Serialize)]
pub(crate) struct ImageCoverage {
    pub enabled: bool,
    pub vectors: i64,
    pub pending: bool,
    pub limited: bool,
    pub vector_limit: i64,
}

fn read_has_vectors(conn: &Connection) -> Result<bool> {
    let Some(rules) = Rules::read(conn)? else {
        return Ok(false);
    };
    let mut stmt = conn.prepare_cached(&format!("SELECT i.path {IMAGE_LIVE}"))?;
    for (lower, upper) in rules.bounds() {
        let mut rows = stmt.query(params![MODEL_ID, lower, upper, LEGACY_VECTOR_BYTES])?;
        while let Some(row) = rows.next()? {
            if rules.allows(Path::new(row.get_ref(0)?.as_str()?)) {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

pub(crate) fn has_vectors(conn: &Connection) -> Result<bool> {
    if conn.is_autocommit() {
        read_snapshot(conn, read_has_vectors)
    } else {
        read_has_vectors(conn)
    }
}

fn bounds_clause(bounds: &[(String, String)], values: &mut Vec<rusqlite::types::Value>) -> String {
    let mut clauses = Vec::with_capacity(bounds.len());
    for (lower, upper) in bounds {
        let lo = values.len() + 1;
        let hi = lo + 1;
        clauses.push(format!("(i.path>=?{lo} AND i.path<?{hi})"));
        values.push(lower.clone().into());
        values.push(upper.clone().into());
    }
    clauses.join(" OR ")
}

fn build_pending_query(
    bounds: &[(String, String)],
    use_mtime_index: bool,
    has_embeddings: bool,
    has_skip: bool,
) -> (String, Vec<rusqlite::types::Value>) {
    let indexed_by = if use_mtime_index {
        " INDEXED BY item_image_mtime"
    } else {
        ""
    };
    let mut values: Vec<rusqlite::types::Value> = Vec::new();
    let mut extra_filters = String::new();
    if has_embeddings || has_skip {
        values.push(MODEL_ID.to_owned().into());
    }
    if has_embeddings {
        values.push(LEGACY_VECTOR_BYTES.into());
        extra_filters.push_str(
            " AND NOT EXISTS(SELECT 1 FROM image_embedding e WHERE e.id=i.id AND e.model=?1 AND typeof(e.vector)='blob' AND length(e.vector) IN (?2/2,?2))",
        );
    }
    if has_skip {
        extra_filters
            .push_str(" AND NOT EXISTS(SELECT 1 FROM image_skip s WHERE s.id=i.id AND s.model=?1)");
    }
    let bounds_sql = bounds_clause(bounds, &mut values);
    let sql = format!(
        "SELECT i.path FROM item i{indexed_by} WHERE {IMAGE_ITEM_WHERE} AND ({bounds_sql}){extra_filters}"
    );
    (sql, values)
}

fn has_pending_images(conn: &Connection, rules: &Rules, has_embeddings: bool) -> Result<bool> {
    let bounds: Vec<(String, String)> = rules.bounds().collect();
    if bounds.is_empty() {
        return Ok(false);
    }
    let has_skip = has_table(conn, "image_skip")?;
    let (sql, values) =
        build_pending_query(&bounds, has_mtime_index(conn)?, has_embeddings, has_skip);
    let mut stmt = conn.prepare(&sql)?;
    let mut rows = stmt.query(rusqlite::params_from_iter(values))?;
    while let Some(row) = rows.next()? {
        if rules.allows(Path::new(row.get_ref(0)?.as_str()?)) {
            return Ok(true);
        }
    }
    Ok(false)
}

pub(crate) fn coverage(conn: &Connection) -> Result<ImageCoverage> {
    coverage_with_limit(conn, image_limit())
}

fn coverage_with_limit(conn: &Connection, vector_limit: i64) -> Result<ImageCoverage> {
    let Some(rules) = saved_index_scope(conn)?.and_then(Rules::from_scope) else {
        return Ok(ImageCoverage {
            enabled: false,
            vectors: 0,
            pending: false,
            limited: false,
            vector_limit,
        });
    };
    let has_embeddings = has_table(conn, "image_embedding")?;
    let (vectors, total_stored) = if has_embeddings {
        let vectors = count_images(conn, &rules)?;
        let total: i64 =
            conn.query_row("SELECT count(*) FROM image_embedding", [], |r| r.get(0))?;
        (vectors, total)
    } else {
        (0, 0)
    };
    let pending = has_pending_images(conn, &rules, has_embeddings)?;
    let limited = pending && total_stored >= vector_limit;
    Ok(ImageCoverage {
        enabled: true,
        vectors,
        pending,
        limited,
        vector_limit,
    })
}

fn format_cursor(mtime: i64, id: i64) -> String {
    format!("mtime:{mtime}:{id}")
}

fn parse_cursor(after: Option<&str>) -> Result<Option<(i64, i64)>> {
    let Some(after) = after.filter(|s| !s.is_empty()) else {
        return Ok(None);
    };
    let Some(rest) = after.strip_prefix("mtime:") else {
        bail!("invalid image cursor");
    };
    let Some((mtime, id)) = rest.split_once(':') else {
        bail!("invalid image cursor");
    };
    let mtime: i64 = mtime
        .parse()
        .map_err(|_| anyhow::anyhow!("invalid image cursor"))?;
    let id: i64 = id
        .parse()
        .map_err(|_| anyhow::anyhow!("invalid image cursor"))?;
    Ok(Some((mtime, id)))
}

fn build_batch_query(
    bounds: &[(String, String)],
    use_mtime_index: bool,
    has_skip: bool,
    cursor: Option<(i64, i64)>,
    limit: usize,
) -> (String, Vec<rusqlite::types::Value>) {
    let indexed_by = if use_mtime_index {
        " INDEXED BY item_image_mtime"
    } else {
        ""
    };
    let mut values: Vec<rusqlite::types::Value> =
        vec![MODEL_ID.to_owned().into(), LEGACY_VECTOR_BYTES.into()];
    let bounds_sql = bounds_clause(bounds, &mut values);
    let skip_sql = if has_skip {
        " AND NOT EXISTS(SELECT 1 FROM image_skip s WHERE s.id=i.id AND s.model=?1)"
    } else {
        ""
    };
    let cursor_sql = if let Some((cursor_mtime, cursor_id)) = cursor {
        let m = values.len() + 1;
        let id = m + 1;
        values.push(cursor_mtime.into());
        values.push(cursor_id.into());
        format!(" AND i.mtime<=?{m} AND (i.mtime<?{m} OR (i.mtime=?{m} AND i.id<?{id}))")
    } else {
        String::new()
    };
    let limit_idx = values.len() + 1;
    values.push((limit as i64).into());
    let sql = format!(
        "SELECT i.id,i.path,i.mtime,CASE WHEN e.model=?1 AND typeof(e.vector)='blob'
            AND length(e.vector) IN (?2/2,?2) THEN e.stamp END,e.id IS NOT NULL
         FROM item i{indexed_by} LEFT JOIN image_embedding e ON i.id=e.id
         WHERE {IMAGE_ITEM_WHERE}
           AND ({bounds_sql}){skip_sql}{cursor_sql}
         ORDER BY i.mtime DESC, i.id DESC LIMIT ?{limit_idx}"
    );
    (sql, values)
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
    let cursor = parse_cursor(after)?;
    let limit = image_limit();
    let mut available = limit
        - snapshot.query_row("SELECT count(*) FROM image_embedding", [], |r| {
            r.get::<_, i64>(0)
        })?;
    let bounds: Vec<(String, String)> = rules.bounds().collect();
    let rows = if bounds.is_empty() {
        Vec::new()
    } else {
        let (sql, values) = build_batch_query(
            &bounds,
            has_mtime_index(&snapshot)?,
            has_table(&snapshot, "image_skip")?,
            cursor,
            max + 1,
        );
        let mut stmt = snapshot.prepare(&sql)?;
        stmt.query_map(rusqlite::params_from_iter(values), |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, Option<String>>(3)?,
                r.get::<_, bool>(4)?,
            ))
        })?
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
        next_after: (total_rows > max).then(|| format_cursor(rows[max - 1].2, rows[max - 1].0)),
    };
    let mut encoded = Vec::new();
    let mut skips = Vec::new();
    let mut stopped = false;
    let mut last_cursor = None;
    for (idx, (id, path, mtime, prior, occupied)) in rows.into_iter().take(max).enumerate() {
        if stop.is_some_and(|flag| flag.load(Ordering::Acquire)) {
            if idx == 0 {
                return Ok((None, true));
            }
            batch.processed = idx;
            batch.next_after = last_cursor.filter(|_| total_rows > idx);
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
        if !rules.allows(source) {
            last_cursor = Some(format_cursor(mtime, id));
            batch.skipped += 1;
            continue;
        }
        let Some(stamp) = local_stamp(source, false) else {
            last_cursor = Some(format_cursor(mtime, id));
            batch.skipped += 1;
            skips.push((id, format!("unreadable:{mtime}")));
            continue;
        };
        if prior
            .as_deref()
            .is_some_and(|prior| crate::index::stamp_matches(prior, &stamp))
        {
            last_cursor = Some(format_cursor(mtime, id));
            batch.reused += 1;
            continue;
        }
        if !occupied && available <= 0 {
            last_cursor = Some(format_cursor(mtime, id));
            batch.limited = true;
            batch.skipped += 1;
            continue;
        }
        let Ok(bytes) = platform::read_local_checked(source, MAX_FILE_BYTES, Some(&stamp)) else {
            last_cursor = Some(format_cursor(mtime, id));
            batch.skipped += 1;
            skips.push((id, stamp));
            continue;
        };
        let Some(bytes) = thumbnail(&bytes) else {
            last_cursor = Some(format_cursor(mtime, id));
            batch.skipped += 1;
            skips.push((id, stamp));
            continue;
        };
        let worker = match worker {
            Some(worker) => worker,
            None => worker.insert(connect.take().expect("image worker connects once")()?),
        };
        let vector = worker.encode_image_bytes(&bytes)?;
        available -= i64::from(!occupied);
        last_cursor = Some(format_cursor(mtime, id));
        encoded.push((id, path, stamp, pack(&vector)));
    }
    if encoded.is_empty() && skips.is_empty() {
        return Ok((Some((batch, rules)), stopped));
    }

    if writer.is_none() {
        *writer = Some(open_write(database, false)?.0);
    }
    let conn = writer.as_mut().expect("opened writer connection");
    ensure_schema(conn)?;
    let txn = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if Rules::read(&txn)?.as_ref() != Some(&rules) {
        if yield_on_scope_change {
            return Ok((None, true));
        }
        bail!("image or filename scope changed; retry the batch");
    }
    for (id, skip_stamp) in skips {
        txn.execute(
            "INSERT INTO image_skip VALUES (?1,?2,?3)
             ON CONFLICT(id) DO UPDATE SET model=excluded.model,stamp=excluded.stamp",
            params![id, MODEL_ID, skip_stamp],
        )?;
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
        if !existing && total >= limit {
            batch.skipped += 1;
            batch.limited = true;
            continue;
        }
        txn.execute(
            "INSERT INTO image_embedding VALUES (?1,?2,?3,?4)
             ON CONFLICT(id) DO UPDATE SET model=excluded.model,stamp=excluded.stamp,vector=excluded.vector",
            params![id, MODEL_ID, stamp, packed],
        )?;
        txn.execute("DELETE FROM image_skip WHERE id=?1", [id])?;
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

/// Image vectors cached for blending into unified semantic results.
pub(crate) type ImageCache = MatrixCache<ImageRow>;

/// Rank stored image vectors against an already encoded text query. The text
/// tower is shared, so semantic search needs no extra worker for this.
pub(crate) fn rank_with_query(
    conn: &Connection,
    cache: &mut ImageCache,
    query: &[f32],
    limit: usize,
) -> Result<Vec<Hit>> {
    read_snapshot(conn, |snapshot| {
        Ok(rank_images(
            cache.get_for_bucket(snapshot, "img_generation", load_images)?,
            query,
            limit,
        ))
    })
}

pub(crate) struct ImageRow {
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
    let mut stmt = snapshot.prepare_cached(&format!(
        "SELECT i.path,i.display,i.availability,e.stamp,e.vector {IMAGE_LIVE}"
    ))?;
    for (lower, upper) in rules.bounds() {
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
            // Image vectors follow content_filter.enable_images in the one saved scope.
            "UPDATE info SET value=json_set(value,'$.content_filter',json('{\"enable_images\":false}')) WHERE key='scope'",
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
            writer.execute_batch("UPDATE info SET value=json_remove(json_set(value,'$.deny',json('[]')),'$.content_filter') WHERE key='scope'; UPDATE item SET availability='local' WHERE display='sample.png'").unwrap();
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

    #[test]
    fn legacy_image_scope_migrates_once_into_content_roots_which_drive_image_status() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-image-unified-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let (photos, docs) = (root.join("photos"), root.join("docs"));
        fs::create_dir_all(&photos).unwrap();
        fs::create_dir_all(&docs).unwrap();
        let (photo, scan) = (photos.join("a.png"), docs.join("b.jpg"));
        fs::write(&photo, "image").unwrap();
        fs::write(&scan, "image").unwrap();
        fs::write(docs.join("notes.txt"), "notes").unwrap();
        let database = root.join("index.db");
        crate::scan(
            &database,
            &Scope {
                roots: vec![root.clone()],
                content_roots: Some(vec![docs.clone()]),
                documents: true,
                ..Scope::default()
            },
        )
        .unwrap();
        // An index written by the previous engine kept a second, image-only list.
        let legacy = Connection::open(&database).unwrap();
        legacy
            .execute(
                "INSERT OR REPLACE INTO image_scope VALUES(1,?1,3)",
                [photos.to_str().unwrap()],
            )
            .unwrap();
        // Readers never treat the legacy row as authority.
        assert_eq!(
            image_status(&database).unwrap().roots,
            [docs.to_str().unwrap()]
        );
        drop(crate::open_write(&database, false).unwrap());
        let saved = saved_index_scope(&legacy).unwrap().unwrap();
        assert_eq!(
            saved.content_roots,
            Some(vec![docs.clone(), photos.clone()])
        );
        assert!(saved.documents && saved.content_filter.enable_images);
        let leftover: Option<String> = legacy
            .query_row("SELECT root FROM image_scope WHERE id=1", [], |r| r.get(0))
            .unwrap();
        assert_eq!(leftover, None);
        let status = image_status(&database).unwrap();
        assert_eq!(
            status.roots,
            [docs.to_str().unwrap(), photos.to_str().unwrap()]
        );
        // The migration re-seeds content jobs for the merged folder on the next pass.
        crate::apply_content_scope(&database, saved.content_roots.clone().unwrap(), false).unwrap();
        // Store one vector per folder, then turn images off through the adapter.
        for path in [&photo, &scan] {
            legacy
                .execute(
                    "INSERT INTO image_embedding SELECT id,?1,?2,?3 FROM item WHERE path=?4",
                    params![
                        MODEL_ID,
                        local_stamp(path, false).unwrap(),
                        pack(&query_vector()),
                        path.to_str().unwrap()
                    ],
                )
                .unwrap();
        }
        assert_eq!(image_status(&database).unwrap().vectors, 2);
        // Narrowing content_roots drops the other folder's vectors too.
        crate::apply_content_scope(&database, vec![docs.clone()], false).unwrap();
        assert_eq!(image_status(&database).unwrap().vectors, 1);
        let cleared = image_scope(&database, None).unwrap();
        assert_eq!((cleared.root, cleared.vectors), (None, 0));
        let stored: i64 = legacy
            .query_row("SELECT count(*) FROM image_embedding", [], |r| r.get(0))
            .unwrap();
        assert_eq!(stored, 0);
        let kept = saved_index_scope(&legacy).unwrap().unwrap();
        assert_eq!(kept.content_roots, Some(vec![docs.clone()]));
        assert!(kept.documents && !kept.content_filter.enable_images);
        // Re-enabling through the adapter adds the folder to the same list.
        let enabled = image_scope(&database, Some(&photos)).unwrap();
        assert_eq!(enabled.root.as_deref(), photos.to_str());
        assert_eq!(
            enabled.roots,
            [docs.to_str().unwrap(), photos.to_str().unwrap()]
        );
        drop(legacy);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn adding_an_image_folder_never_narrows_legacy_whole_scope_documents() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-image-legacy-docs-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let (photos, docs) = (root.join("photos"), root.join("docs"));
        fs::create_dir_all(&photos).unwrap();
        fs::create_dir_all(&docs).unwrap();
        fs::write(photos.join("a.png"), "image").unwrap();
        fs::write(docs.join("notes.txt"), "legacy whole scope prose").unwrap();
        let database = root.join("index.db");
        // Legacy mode: documents everywhere in the scope, no content_roots.
        crate::scan(
            &database,
            &Scope {
                roots: vec![root.clone()],
                documents: true,
                ..Scope::default()
            },
        )
        .unwrap();
        let documents = |database: &Path| -> i64 {
            open_read(database)
                .unwrap()
                .query_row("SELECT count(*) FROM document", [], |r| r.get(0))
                .unwrap()
        };
        assert_eq!(documents(&database), 1);
        let legacy = Connection::open(&database).unwrap();
        legacy
            .execute(
                "INSERT OR REPLACE INTO image_scope VALUES(1,?1,1)",
                [photos.to_str().unwrap()],
            )
            .unwrap();
        drop(crate::open_write(&database, false).unwrap());
        let migrated = saved_index_scope(&legacy).unwrap().unwrap();
        assert_eq!(migrated.content_roots, Some(vec![root.clone()]));
        // The adapter path keeps the same coverage too.
        image_scope(&database, Some(&photos)).unwrap();
        let adapted = saved_index_scope(&legacy).unwrap().unwrap();
        assert_eq!(adapted.content_roots, Some(vec![root.clone()]));
        assert_eq!(documents(&database), 1);
        drop(legacy);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn image_limit_scales_with_physical_memory_and_clamps_bounds() {
        const GIB: u64 = 1024 * 1024 * 1024;
        const BYTES_PER_VEC: u64 = (DIMENSIONS as u64) * 2;
        assert!(SCHEMA.contains(CREATE_IMAGE_MTIME_INDEX));
        assert_eq!(
            image_limit_for_memory(2 * GIB),
            (MIN_IMAGE_VECTOR_BYTES / BYTES_PER_VEC) as i64
        );
        assert_eq!(
            image_limit_for_memory(8 * GIB),
            ((8 * GIB / 100) / BYTES_PER_VEC) as i64
        );
        assert_eq!(
            image_limit_for_memory(16 * GIB),
            ((16 * GIB / 100) / BYTES_PER_VEC) as i64
        );
        assert_eq!(
            image_limit_for_memory(64 * GIB),
            (MAX_IMAGE_VECTOR_BYTES / BYTES_PER_VEC) as i64
        );
        assert_eq!(
            image_limit_for_memory(128 * GIB),
            (MAX_IMAGE_VECTOR_BYTES / BYTES_PER_VEC) as i64
        );
        assert!(image_limit() >= (MIN_IMAGE_VECTOR_BYTES / BYTES_PER_VEC) as i64);

        assert_eq!(parse_cursor(None).unwrap(), None);
        assert_eq!(parse_cursor(Some("")).unwrap(), None);
        assert_eq!(
            parse_cursor(Some("mtime:1700000000:42")).unwrap(),
            Some((1_700_000_000, 42))
        );
        assert_eq!(parse_cursor(Some("mtime:-5:1")).unwrap(), Some((-5, 1)));
        for invalid in ["/tmp/a.png", "mtime:123", "mtime:1:2:3", "mtime:abc:1"] {
            let err = parse_cursor(Some(invalid)).unwrap_err().to_string();
            assert!(err.contains("invalid image cursor"), "{invalid}: {err}");
        }
    }

    #[test]
    fn mtime_index_covers_batch_and_pending_queries_and_indexes_recent_first_across_roots() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-image-mtime-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let root_a = root.join("aaa");
        let root_z = root.join("zzz");
        fs::create_dir_all(&root_a).unwrap();
        fs::create_dir_all(&root_z).unwrap();
        let png: &[u8] = &[
            0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, b'I', b'H',
            b'D', b'R', 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00,
            0x00, 0x90, 0x77, 0x53, 0xde, 0x00, 0x00, 0x00, 0x0c, b'I', b'D', b'A', b'T', 0x08,
            0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00, 0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xdd, 0x8d,
            0xb0, 0x00, 0x00, 0x00, 0x00, b'I', b'E', b'N', b'D', 0xae, 0x42, 0x60, 0x82,
        ];
        let old_img = root_a.join("old.png");
        let new_img = root_z.join("new.png");
        fs::write(&old_img, png).unwrap();
        fs::write(&new_img, png).unwrap();
        let set_mtime = |path: &Path, secs: i64| {
            let cpath = std::ffi::CString::new(path.to_str().unwrap()).unwrap();
            let times = [
                libc::timeval {
                    tv_sec: secs,
                    tv_usec: 0,
                },
                libc::timeval {
                    tv_sec: secs,
                    tv_usec: 0,
                },
            ];
            assert_eq!(unsafe { libc::utimes(cpath.as_ptr(), times.as_ptr()) }, 0);
        };
        set_mtime(&old_img, 1_700_000_000);
        set_mtime(&new_img, 1_700_010_000);

        let database = root.join("index.db");
        crate::scan(
            &database,
            &Scope {
                roots: vec![root.clone()],
                content_roots: Some(vec![root_a.clone(), root_z.clone()]),
                documents: true,
                ..Scope::default()
            },
        )
        .unwrap();
        image_scope(&database, Some(&root_a)).unwrap();
        image_scope(&database, Some(&root_z)).unwrap();

        let reader = open_read(&database).unwrap();
        assert!(has_mtime_index(&reader).unwrap());
        let rules = Rules::read(&reader).unwrap().unwrap();
        let bounds: Vec<(String, String)> = rules.bounds().collect();
        assert_eq!(bounds.len(), 2);

        let explain = |sql: &str, values: Vec<rusqlite::types::Value>| -> Vec<String> {
            let mut stmt = reader
                .prepare(&format!("EXPLAIN QUERY PLAN {sql}"))
                .unwrap();
            stmt.query_map(rusqlite::params_from_iter(values), |r| {
                r.get::<_, String>(3)
            })
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap()
        };
        let (batch_sql, batch_vals) = build_batch_query(&bounds, true, true, None, 2);
        let batch_plan = explain(&batch_sql, batch_vals).join(" | ");
        assert!(
            batch_plan.contains("COVERING INDEX item_image_mtime"),
            "unexpected batch plan: {batch_plan}"
        );
        assert!(
            !batch_plan.contains("TEMP B-TREE"),
            "batch query should not sort with temp b-tree: {batch_plan}"
        );
        let (cursor_sql, cursor_vals) =
            build_batch_query(&bounds, true, true, Some((1_700_010_000, 99)), 2);
        let cursor_plan = explain(&cursor_sql, cursor_vals).join(" | ");
        assert!(
            cursor_plan.contains("COVERING INDEX item_image_mtime"),
            "unexpected cursor batch plan: {cursor_plan}"
        );
        assert!(
            !cursor_plan.contains("TEMP B-TREE"),
            "cursor batch query should not sort with temp b-tree: {cursor_plan}"
        );
        let (pending_sql, pending_vals) = build_pending_query(&bounds, true, true, true);
        let pending_plan = explain(&pending_sql, pending_vals).join(" | ");
        assert!(
            pending_plan.contains("COVERING INDEX item_image_mtime"),
            "unexpected pending plan: {pending_plan}"
        );

        assert!(!has_vectors(&reader).unwrap());
        let before = coverage(&reader).unwrap();
        assert!(before.enabled);
        assert_eq!(before.vectors, 0);
        assert!(before.pending);
        assert!(!before.limited);
        assert_eq!(before.vector_limit, image_limit());

        struct FixedEncoder;
        impl ImageEncoder for FixedEncoder {
            fn encode_image_bytes(&mut self, _: &[u8]) -> Result<Vec<f32>> {
                Ok(query_vector())
            }
        }
        let mut writer = None;
        let mut worker = None;
        let mut connect = Some(|| Ok(FixedEncoder));
        let (step1, _) = image_batch_step(
            &database,
            &reader,
            &mut writer,
            &mut connect,
            &mut worker,
            None,
            1,
            None,
            None,
            false,
        )
        .unwrap();
        let (batch1, _) = step1.unwrap();
        assert_eq!((batch1.processed, batch1.indexed), (1, 1));
        assert!(
            batch1
                .next_after
                .as_deref()
                .is_some_and(|cursor| cursor.starts_with("mtime:"))
        );
        let first_indexed_path: String = reader
            .query_row(
                "SELECT i.path FROM image_embedding e JOIN item i USING(id)",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            first_indexed_path,
            new_img.to_str().unwrap(),
            "newer zzz/new.png must be indexed before older aaa/old.png"
        );
        assert!(has_vectors(&reader).unwrap());
        let mid = coverage(&reader).unwrap();
        assert!(mid.enabled && mid.vectors == 1 && mid.pending && !mid.limited);
        let capped = coverage_with_limit(&reader, 1).unwrap();
        assert!(capped.enabled && capped.vectors == 1 && capped.pending && capped.limited);

        let (step2, _) = image_batch_step(
            &database,
            &reader,
            &mut writer,
            &mut connect,
            &mut worker,
            batch1.next_after.as_deref(),
            1,
            None,
            None,
            false,
        )
        .unwrap();
        let (batch2, _) = step2.unwrap();
        assert_eq!((batch2.processed, batch2.indexed), (1, 1));
        assert_eq!(batch2.next_after, None);

        let after = coverage(&reader).unwrap();
        assert!(after.enabled);
        assert_eq!(after.vectors, 2);
        assert!(!after.pending);
        assert!(!after.limited);
        assert_eq!(after.vector_limit, image_limit());

        let report = crate::status(&reader).unwrap();
        assert_eq!(report["images"]["enabled"], true);
        assert_eq!(report["images"]["vectors"], 2);
        assert_eq!(report["images"]["pending"], false);
        assert_eq!(report["images"]["limited"], false);
        assert_eq!(report["images"]["vector_limit"], image_limit());

        // An un-decodable / corrupt image is recorded in image_skip so coverage().pending settles to false
        // until the item's mtime changes.
        let bad_img = root_z.join("bad.png");
        fs::write(&bad_img, b"not a valid png payload").unwrap();
        set_mtime(&bad_img, 1_700_020_000);
        crate::scan(
            &database,
            &Scope {
                roots: vec![root.clone()],
                content_roots: Some(vec![root_a.clone(), root_z.clone()]),
                documents: true,
                ..Scope::default()
            },
        )
        .unwrap();
        assert!(coverage(&reader).unwrap().pending);
        let (skip_step, _) = image_batch_step(
            &database,
            &reader,
            &mut writer,
            &mut connect,
            &mut worker,
            None,
            4,
            None,
            None,
            false,
        )
        .unwrap();
        assert_eq!(skip_step.unwrap().0.skipped, 1);
        assert!(!coverage(&reader).unwrap().pending);

        // Updating mtime on item clears image_skip via SQLite trigger so it becomes pending again.
        let tx = writer.as_mut().unwrap();
        tx.execute(
            "UPDATE item SET mtime=?1 WHERE path=?2",
            params![1_700_030_000_i64, bad_img.to_str().unwrap()],
        )
        .unwrap();
        assert!(coverage(&reader).unwrap().pending);

        drop(writer);
        drop(reader);
        fs::remove_dir_all(root).unwrap();
    }
}
