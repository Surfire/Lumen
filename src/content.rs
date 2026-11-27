use crate::index::{
    Coverage, DocumentKind, ImageOcrExtractor, can_open_document, check_document_access,
    document_version, document_version_matches, extract_document, remove_document,
    resident_content_availability, restrict_scope, save_document,
};
use crate::{
    ContentCategory, ContentFilter, MAX_DOCUMENT, PdfHelperPolicy, Scope, absolute, open_read,
    open_write, platform,
};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs,
    io::{self, ErrorKind},
    path::{Path, PathBuf},
};

pub(super) const SCHEMA: &str = "
    CREATE TABLE IF NOT EXISTS content_job(item_id INTEGER PRIMARY KEY, stamp TEXT);
    CREATE INDEX IF NOT EXISTS content_job_pending ON content_job(item_id) WHERE stamp IS NULL;
    CREATE TRIGGER IF NOT EXISTS content_job_delete AFTER DELETE ON item
    BEGIN DELETE FROM content_job WHERE item_id=old.id; END;
    CREATE TABLE IF NOT EXISTS pdf_page(document_id INTEGER NOT NULL, page INTEGER NOT NULL,
        start_byte INTEGER NOT NULL, end_byte INTEGER NOT NULL, PRIMARY KEY(document_id,page));
    CREATE TRIGGER IF NOT EXISTS pdf_pages_delete AFTER DELETE ON document
    BEGIN DELETE FROM pdf_page WHERE document_id=old.id; END;
";

fn saved_scope(conn: &Connection) -> Result<(String, Scope)> {
    let raw: String =
        conn.query_row("SELECT value FROM info WHERE key='scope'", [], |r| r.get(0))?;
    let scope = serde_json::from_str(&raw)?;
    Ok((raw, scope))
}

pub fn apply_content_scope(
    database: &Path,
    roots: Vec<PathBuf>,
    bundled_pdf: bool,
) -> Result<serde_json::Value> {
    apply_content_scope_with_image_ocr(database, roots, bundled_pdf, false)
}

pub fn apply_content_scope_with_image_ocr(
    database: &Path,
    roots: Vec<PathBuf>,
    bundled_pdf: bool,
    image_ocr: bool,
) -> Result<serde_json::Value> {
    apply_content_scope_with_filter(database, roots, bundled_pdf, image_ocr, None)
}

/// Apply content roots and, when given, a new content filter. Without a filter
/// the saved one is kept.
pub fn apply_content_scope_with_filter(
    database: &Path,
    roots: Vec<PathBuf>,
    bundled_pdf: bool,
    image_ocr: bool,
    filter: Option<ContentFilter>,
) -> Result<serde_json::Value> {
    update_scope(database, |scope| {
        scope.documents = !roots.is_empty();
        scope.content_roots = Some(roots);
        scope.image_ocr = image_ocr;
        scope.pdf_helper = if scope.documents && !bundled_pdf {
            scope.pdf_helper.take()
        } else {
            None
        };
        scope.pdf_helper_policy = if !scope.documents {
            None
        } else if bundled_pdf {
            Some(PdfHelperPolicy::Bundled)
        } else {
            scope.pdf_helper_policy
        };
        if let Some(filter) = filter {
            scope.content_filter = filter;
        }
        Ok(())
    })
}

/// The one write path for content settings (`content-scope` and the
/// `image-scope` compatibility adapter): edit the saved scope, then reconcile.
pub(crate) fn update_scope(
    database: &Path,
    change: impl FnOnce(&mut Scope) -> Result<()>,
) -> Result<serde_json::Value> {
    #[cfg(target_os = "macos")]
    let _io = platform::NoMaterialization::enter()?;
    let database = absolute(database)?;
    drop(open_read(&database)?);
    let (mut conn, _lease) = open_write(&database, true)?;
    conn.execute_batch(crate::image_search::SCHEMA)?;
    let (_, mut scope) = saved_scope(&conn)?;
    change(&mut scope)?;
    let coverage = Coverage::new(database, &scope)?;
    restrict_scope(&mut conn, &coverage)?;
    let mut report = crate::status(&conn)?;
    report["scope"] = serde_json::json!({
        "roots": coverage.scope.roots, "allow": coverage.scope.allow, "deny": coverage.scope.deny,
        "documents": coverage.scope.documents, "content_roots": coverage.scope.content_roots,
        "image_ocr": coverage.scope.image_ocr, "content_filter": coverage.scope.content_filter,
    });
    Ok(report)
}

pub(super) fn restrict_and_seed(conn: &Connection, coverage: &Coverage) -> Result<()> {
    fn retired(conn: &Connection, coverage: &Coverage, sql: &str) -> Result<Vec<i64>> {
        let mut statement = conn.prepare(sql)?;
        let mut rows = statement.query([])?;
        let mut ids = Vec::new();
        while let Some(row) = rows.next()? {
            let path: String = row.get(1)?;
            let path = Path::new(&path);
            let availability: String = row.get(2)?;
            // Keep access gaps for watch to revalidate. They are not runnable jobs.
            if !coverage.permits_content(path)
                || eligible_kind(coverage, path).is_none()
                || (availability != "unverified"
                    && !resident_content_availability(
                        &availability,
                        coverage.scope.content_roots.is_some(),
                    ))
            {
                ids.push(row.get(0)?);
            }
        }
        Ok(ids)
    }
    for id in retired(
        conn,
        coverage,
        "SELECT i.id,i.path,i.availability FROM document d JOIN item i USING(id)",
    )? {
        remove_document(conn, id)?;
    }
    for id in retired(
        conn,
        coverage,
        "SELECT i.id,i.path,i.availability FROM content_job j JOIN item i ON i.id=j.item_id",
    )? {
        conn.prepare_cached("DELETE FROM content_job WHERE item_id=?")?
            .execute([id])?;
    }
    if let Some(roots) = &coverage.scope.content_roots {
        let mut select = conn.prepare("SELECT id,path FROM item WHERE path>=?1 AND path<?2 AND kind='file' AND availability IN ('local','provider_metadata_only')")?;
        let mut add = conn.prepare("INSERT OR IGNORE INTO content_job(item_id) VALUES(?)")?;
        for root in roots {
            let Some(root) = root.to_str() else {
                continue;
            };
            let mut rows = select.query(params![format!("{root}/"), format!("{root}0")])?;
            while let Some(row) = rows.next()? {
                let path: String = row.get(1)?;
                if coverage.permits_content(Path::new(&path))
                    && eligible_kind(coverage, Path::new(&path)).is_some()
                {
                    add.execute([row.get::<_, i64>(0)?])?;
                }
            }
        }
    }
    Ok(())
}

pub(super) fn eligible_kind(coverage: &Coverage, path: &Path) -> Option<DocumentKind> {
    let scope = &coverage.scope;
    let filter = &scope.content_filter;
    if filter.excludes(path, scope.content_roots.as_deref().unwrap_or(&scope.roots)) {
        return None;
    }
    DocumentKind::for_path(path).filter(|kind| match kind {
        // OCR keeps its own opt-in; `enable_images` governs image vectors.
        DocumentKind::Image => scope.image_ocr,
        DocumentKind::Pdf => coverage.pdf.is_some() && filter.category(path).is_some(),
        _ => filter.category(path).is_some(),
    })
}

pub(super) struct Observation {
    version: Option<String>,
    verified: bool,
}

/// Prepare the version and, if there is already a body to publish, verify
/// read access. Neither operation belongs inside the writer's transaction.
pub(super) fn prepare(
    conn: &Connection,
    coverage: &Coverage,
    path: &Path,
    metadata: Option<&fs::Metadata>,
    kind: DocumentKind,
) -> Result<Option<Observation>> {
    let version = metadata.map(|meta| document_version(coverage, kind, meta));
    let mut verified = false;
    if let Some(meta) = metadata {
        let has_body: bool = conn
            .prepare_cached(
                "SELECT EXISTS(SELECT 1 FROM item JOIN document USING(id) WHERE path=?)",
            )?
            .query_row([path.to_str().expect("checked UTF-8 path")], |r| r.get(0))?;
        if has_body {
            if !can_open_document(path, meta) {
                return Ok(None);
            }
            verified = true;
        }
    }
    Ok(Some(Observation { version, verified }))
}

pub(super) fn observe(conn: &Connection, id: i64, observation: &Observation) -> Result<bool> {
    let version = observation.version.as_deref();
    // An orphaned body (e.g. a cleared stamp in an older catalog) is stale,
    // as is any body added since preparation that we did not verify.
    let verified_version = version.filter(|_| observation.verified);
    let existing_doc: Option<Option<String>> = conn
        .prepare_cached(
            "SELECT s.stamp FROM document d LEFT JOIN document_state s USING(id) WHERE d.id=?1",
        )?
        .query_row([id], |r| r.get(0))
        .optional()?;
    let stale = match existing_doc {
        Some(Some(stored)) => {
            !verified_version.is_some_and(|current| document_version_matches(&stored, current))
        }
        Some(None) => true,
        None => false,
    };
    if stale {
        remove_document(conn, id)?;
    }
    let existing_job: Option<Option<String>> = conn
        .prepare_cached("SELECT stamp FROM content_job WHERE item_id=?1")?
        .query_row([id], |r| r.get(0))
        .optional()?;
    let changed = match existing_job {
        None => {
            conn.prepare_cached("INSERT INTO content_job(item_id) VALUES(?1)")?
                .execute([id])?
                != 0
        }
        Some(Some(job_stamp))
            if stale
                || !version
                    .is_some_and(|current| document_version_matches(&job_stamp, current)) =>
        {
            conn.prepare_cached("UPDATE content_job SET stamp=NULL WHERE item_id=?1")?
                .execute([id])?
                != 0
        }
        Some(_) => false,
    };
    Ok(stale || changed)
}

pub(super) fn retire(conn: &Connection, id: i64) -> Result<bool> {
    let job = conn
        .prepare_cached("DELETE FROM content_job WHERE item_id=?")?
        .execute([id])?
        != 0;
    Ok(remove_document(conn, id)? || job)
}

#[derive(Default, Deserialize, Serialize)]
pub struct ContentBatch {
    pub processed: usize,
    pub indexed: usize,
    pub pending: i64,
    #[serde(default)]
    pub skipped: usize,
}

#[derive(Default, Serialize)]
pub(super) struct ContentCoverage {
    pub pending: i64,
    pub checked: i64,
    pub total: i64,
}

pub(super) fn coverage(conn: &Connection) -> Result<ContentCoverage> {
    if !has_table(conn, "content_job")? {
        return Ok(ContentCoverage::default());
    }
    // Scope reconciliation and the watcher keep jobs inside explicit roots.
    Ok(conn.query_row(
        "SELECT count(*)-count(j.stamp),count(j.stamp),count(*)
        FROM content_job j JOIN item i ON i.id=j.item_id WHERE i.availability IN ('local','provider_metadata_only')",
        [],
        |r| {
            Ok(ContentCoverage {
                pending: r.get(0)?,
                checked: r.get(1)?,
                total: r.get(2)?,
            })
        },
    )?)
}

/// A position in the newest-first job order `(item.mtime DESC, item_id ASC)`.
type JobPosition = (i64, i64);
/// Before the newest job.
const JOBS_TOP: JobPosition = (i64::MAX, i64::MIN);
/// After the oldest job.
const JOBS_END: JobPosition = (i64::MIN, i64::MAX);
/// Small resident text/DOCX files extracted together on scoped threads.
const PARALLEL_WORKERS: usize = 8;

fn parse_position(raw: &str) -> Option<JobPosition> {
    let (mtime, id) = raw.split_once(':')?;
    Some((mtime.parse().ok()?, id.parse().ok()?))
}

fn cached_stamp(conn: &Connection, id: i64) -> Result<Option<String>> {
    Ok(conn
        .prepare_cached("SELECT stamp FROM document_state WHERE id=?")?
        .query_row([id], |r| r.get::<_, String>(0))
        .optional()?)
}

fn save_cursor(conn: &Connection, (mtime, id): JobPosition) -> Result<()> {
    conn.prepare_cached(
        "INSERT INTO info(key,value) VALUES('content_cursor',?1)
         ON CONFLICT(key) DO UPDATE SET value=excluded.value",
    )?
    .execute([format!("{mtime}:{id}")])?;
    Ok(())
}

/// Text and OOXML Office files are read in-process; PDF and OCR run helpers with
/// their own deadlines and stay sequential.
fn parallel_kind(coverage: &Coverage, path: &Path) -> bool {
    matches!(
        eligible_kind(coverage, path),
        Some(DocumentKind::Text | DocumentKind::Docx | DocumentKind::Xlsx | DocumentKind::Pptx)
    ) && coverage.permits_content(path)
}

pub fn index_content(database: &Path, max: usize) -> Result<ContentBatch> {
    #[cfg(target_os = "macos")]
    let _io = platform::NoMaterialization::enter()?;
    let database = absolute(database)?;
    let reader = open_read(&database)?;
    let (_, saved) = saved_scope(&reader)?;
    ensure!(
        saved.content_roots.is_some(),
        "select document folders before indexing content"
    );
    drop(reader);
    let (mut conn, _) = open_write(&database, false)?;
    let (scope_identity, scope) = saved_scope(&conn)?;
    let configured = Coverage::new(database, &scope)?;
    let ocr = scope
        .image_ocr
        .then(ImageOcrExtractor::bundled)
        .transpose()?;
    let mut batch = ContentBatch::default();
    let started = std::time::Instant::now();
    let limit = max.clamp(1, 32);
    let cursor = conn
        .query_row(
            "SELECT value FROM info WHERE key='content_cursor'",
            [],
            |r| r.get::<_, String>(0),
        )
        .optional()?
        .as_deref()
        .and_then(parse_position)
        .unwrap_or(JOBS_TOP);
    // Jobs queued while this batch runs wait for the next invocation.
    let upper: i64 = conn.query_row(
        "SELECT coalesce(max(item_id),0) FROM content_job",
        [],
        |r| r.get(0),
    )?;
    let mut attempted = false;
    // Newest documents first. Wrap once, and never try the same pending job
    // twice in this invocation. Only completed jobs count toward --max; skip
    // fast failures until the time budget expires, then resume after the last
    // attempt on the next run so a failing job cannot starve the others.
    'batch: for (mut after, end) in [(cursor, JOBS_END), (JOBS_TOP, cursor)] {
        loop {
            if batch.processed >= limit
                || (attempted && started.elapsed() >= std::time::Duration::from_secs(2))
                || saved_scope(&conn)?.0 != scope_identity
            {
                break 'batch;
            }
            let jobs: Vec<Job> = conn
                .prepare_cached(
                    "SELECT i.id,i.path,i.mtime FROM content_job j JOIN item i ON i.id=j.item_id
                     WHERE j.stamp IS NULL AND i.availability IN ('local','provider_metadata_only')
                       AND (i.mtime<?1 OR (i.mtime=?1 AND j.item_id>?2))
                       AND (i.mtime>?3 OR (i.mtime=?3 AND j.item_id<=?4)) AND j.item_id<=?6
                     ORDER BY i.mtime DESC, j.item_id LIMIT ?5",
                )?
                .query_map(
                    params![
                        after.0,
                        after.1,
                        end.0,
                        end.1,
                        (limit - batch.processed) as i64,
                        upper
                    ],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )?
                .collect::<rusqlite::Result<_>>()?;
            let Some(&(last_id, _, last_mtime)) = jobs.last() else {
                break;
            };
            attempted = true;
            // Keep strict newest-first order: consecutive small text/DOCX jobs
            // are extracted together, PDF and OCR jobs one at a time between them.
            let mut group = Vec::new();
            for (id, path, mtime) in jobs {
                if parallel_kind(&configured, Path::new(&path)) {
                    group.push((id, path, mtime));
                    continue;
                }
                let budget = Budget {
                    scope: &scope_identity,
                    limit,
                    started,
                };
                if !flush_group(&mut conn, &configured, &budget, &mut group, &mut batch)? {
                    break 'batch;
                }
                if budget.exhausted(&conn, &batch)? {
                    // Resume at this unattempted job.
                    save_cursor(&conn, (mtime, id.saturating_sub(1)))?;
                    break 'batch;
                }
                save_cursor(&conn, (mtime, id))?;
                // Both metadata passes and extraction must finish before acquiring the
                // SQLite write lock. Recheck the database scope and job under that lock.
                let cached = cached_stamp(&conn, id)?;
                let update =
                    match prepare_update(&configured, ocr.as_ref(), Path::new(&path), cached) {
                        Ok(Some(update)) => update,
                        Ok(None) => {
                            batch.skipped += 1;
                            continue;
                        }
                        Err(error) if has_io_error(&error, ErrorKind::PermissionDenied) => {
                            Update::Denied
                        }
                        Err(error) => return Err(error),
                    };
                let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
                if saved_scope(&tx)?.0 != scope_identity {
                    break 'batch;
                }
                apply_update(&tx, id, &path, update, &mut batch)?;
                tx.commit()?;
            }
            let budget = Budget {
                scope: &scope_identity,
                limit,
                started,
            };
            if !flush_group(&mut conn, &configured, &budget, &mut group, &mut batch)? {
                break 'batch;
            }
            after = (last_mtime, last_id);
        }
    }
    batch.pending = coverage(&conn)?.pending;
    Ok(batch)
}

type Job = (i64, String, i64);

struct Budget<'a> {
    scope: &'a str,
    limit: usize,
    started: std::time::Instant,
}

impl Budget<'_> {
    fn exhausted(&self, conn: &Connection, batch: &ContentBatch) -> Result<bool> {
        Ok(batch.processed >= self.limit
            || self.started.elapsed() >= std::time::Duration::from_secs(2)
            || saved_scope(conn)?.0 != self.scope)
    }
}

/// Extract a run of small documents in parallel and publish them in one
/// writer transaction. Returns false when the batch must stop.
fn flush_group(
    conn: &mut Connection,
    coverage: &Coverage,
    budget: &Budget<'_>,
    group: &mut Vec<Job>,
    batch: &mut ContentBatch,
) -> Result<bool> {
    let Some(&(first_id, _, first_mtime)) = group.first() else {
        return Ok(true);
    };
    if budget.exhausted(conn, batch)? {
        // Resume at the first unattempted job of the group.
        save_cursor(conn, (first_mtime, first_id.saturating_sub(1)))?;
        return Ok(false);
    }
    let &(last_id, _, last_mtime) = group.last().expect("non-empty group");
    save_cursor(conn, (last_mtime, last_id))?;
    let cached = group
        .iter()
        .map(|(id, _, _)| cached_stamp(conn, *id))
        .collect::<Result<Vec<_>>>()?;
    let prepared = extract_parallel(coverage, group, cached);
    // One writer transaction for the whole group, rechecking scope and each
    // job under the lock.
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if saved_scope(&tx)?.0 != budget.scope {
        return Ok(false);
    }
    for ((id, path, _), update) in group.iter().zip(prepared) {
        let update = match update {
            Ok(Some(update)) => update,
            Ok(None) => {
                batch.skipped += 1;
                continue;
            }
            Err(error) if has_io_error(&error, ErrorKind::PermissionDenied) => Update::Denied,
            Err(error) => return Err(error),
        };
        apply_update(&tx, *id, path, update, batch)?;
    }
    tx.commit()?;
    group.clear();
    Ok(true)
}

/// Extract small resident documents concurrently. Every worker thread disables
/// dataless-file materialization for itself before touching any path.
fn extract_parallel(
    coverage: &Coverage,
    jobs: &[Job],
    cached: Vec<Option<String>>,
) -> Vec<Result<Option<Update>>> {
    let next = std::sync::atomic::AtomicUsize::new(0);
    let slots: Vec<std::sync::Mutex<Option<Result<Option<Update>>>>> =
        jobs.iter().map(|_| std::sync::Mutex::new(None)).collect();
    let cached: Vec<std::sync::Mutex<Option<String>>> =
        cached.into_iter().map(std::sync::Mutex::new).collect();
    let workers = jobs.len().min(PARALLEL_WORKERS).min(
        std::thread::available_parallelism()
            .map(usize::from)
            .unwrap_or(1)
            .max(2),
    );
    std::thread::scope(|threads| {
        for _ in 0..workers {
            threads.spawn(|| {
                #[cfg(target_os = "macos")]
                let guard = platform::NoMaterialization::enter();
                loop {
                    let index = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    let Some((_, path, _)) = jobs.get(index) else {
                        break;
                    };
                    #[cfg(target_os = "macos")]
                    if let Err(error) = &guard {
                        *slots[index].lock().expect("slot") = Some(Err(anyhow::anyhow!(
                            "disable APFS materialization: {error}"
                        )));
                        continue;
                    }
                    let stamp = cached[index].lock().expect("stamp").take();
                    let result = prepare_update(coverage, None, Path::new(path), stamp);
                    *slots[index].lock().expect("slot") = Some(result);
                }
            });
        }
    });
    slots
        .into_iter()
        .map(|slot| slot.into_inner().expect("slot").unwrap_or_else(|| Ok(None)))
        .collect()
}

/// Publish one prepared job inside the caller's writer transaction.
fn apply_update(
    tx: &Connection,
    id: i64,
    path: &str,
    update: Update,
    batch: &mut ContentBatch,
) -> Result<()> {
    let pending: bool = tx
        .prepare_cached(
            "SELECT EXISTS(SELECT 1 FROM content_job j JOIN item i ON i.id=j.item_id
            WHERE i.id=?1 AND i.path=?2 AND i.availability IN ('local','provider_metadata_only') AND j.stamp IS NULL)",
        )?
        .query_row(params![id, path], |r| r.get(0))?;
    if !pending {
        return Ok(());
    }
    match update {
        Update::Denied => {
            // A job seeded from the legacy index may still have a body.
            // Clear it now, but keep the job pending for a later retry.
            remove_document(tx, id)?;
            batch.skipped += 1;
            return Ok(());
        }
        Update::Retire => {
            retire(tx, id)?;
        }
        Update::Complete {
            version,
            unchanged,
            extracted,
        } => {
            if let (Some(version), Some(extracted)) = (&version, extracted) {
                save_document(tx, id, version, &extracted)?;
                batch.indexed += 1;
            } else if !unchanged {
                remove_document(tx, id)?;
            }
            tx.prepare_cached("UPDATE content_job SET stamp=?2 WHERE item_id=?1")?
                .execute(params![id, version.as_deref().unwrap_or("unavailable")])?;
        }
    }
    batch.processed += 1;
    Ok(())
}

enum Update {
    Denied,
    Retire,
    Complete {
        version: Option<String>,
        unchanged: bool,
        extracted: Option<Extracted>,
    },
}

fn prepare_update(
    coverage: &Coverage,
    ocr: Option<&ImageOcrExtractor>,
    path: &Path,
    cached: Option<String>,
) -> Result<Option<Update>> {
    let Some(kind) = eligible_kind(coverage, path).filter(|_| coverage.permits_content(path))
    else {
        return Ok(Some(Update::Retire));
    };
    let metadata = || match resident_metadata(path, coverage.scope.content_roots.is_some()) {
        Err(error) if error.kind() != ErrorKind::PermissionDenied => Ok(None),
        result => result,
    };
    let stamp = |meta: &fs::Metadata| document_version(coverage, kind, meta);
    let before = metadata()?;
    let version = before.as_ref().map(stamp);
    let same_version = version
        .as_deref()
        .zip(cached.as_deref())
        .is_some_and(|(live, stored)| document_version_matches(stored, live));
    let unchanged = if let Some(meta) = before.as_ref().filter(|_| same_version) {
        match check_document_access(path, meta) {
            Ok(unchanged) => unchanged,
            Err(error) if error.kind() == ErrorKind::PermissionDenied => return Err(error.into()),
            Err(_) => false,
        }
    } else {
        false
    };
    let extracted = if let Some(meta) = before.as_ref().filter(|_| !unchanged) {
        let extracted = match kind {
            DocumentKind::Image => ocr.context("image OCR is not enabled")?.extract(path, meta),
            _ => extract_document(coverage, path, kind, meta),
        };
        match extracted {
            Ok(extracted) => Some(extracted).filter(|item| !item.body.trim().is_empty()),
            Err(error) if has_io_error(&error, ErrorKind::PermissionDenied) => return Err(error),
            Err(error) if has_io_error(&error, ErrorKind::TimedOut) => return Ok(None),
            Err(_) => None,
        }
    } else {
        None
    };
    if version != metadata()?.as_ref().map(stamp) {
        return Ok(None);
    }
    Ok(Some(Update::Complete {
        version,
        unchanged,
        extracted,
    }))
}

fn has_io_error(error: &anyhow::Error, kind: ErrorKind) -> bool {
    error.chain().any(|cause| {
        cause
            .downcast_ref::<io::Error>()
            .is_some_and(|io| io.kind() == kind)
    })
}

fn resident_metadata(path: &Path, explicit: bool) -> io::Result<Option<fs::Metadata>> {
    // Check ancestors in root order before examining any child. Opening document
    // bytes repeats the engine's no-follow and no-materialization protections.
    let parents: Vec<_> = path.ancestors().skip(1).collect();
    for parent in parents.into_iter().rev() {
        let meta = fs::symlink_metadata(parent)?;
        if !meta.is_dir() || platform::availability(parent, &meta) == "placeholder" {
            return Ok(None);
        }
    }
    let meta = fs::symlink_metadata(path)?;
    Ok((meta.is_file()
        && resident_content_availability(platform::availability(path, &meta), explicit))
    .then_some(meta))
}

pub(super) struct Extracted {
    pub body: String,
    pub pages: Vec<PageSpan>,
}
#[derive(Clone, Copy)]
pub(super) struct PageSpan {
    pub number: u32,
    pub start: usize,
    pub end: usize,
}

pub(super) fn parse_pages(bytes: &[u8]) -> Result<Extracted> {
    #[derive(Deserialize)]
    struct Page {
        page: u32,
        text: String,
    }
    let input: Vec<Page> = serde_json::from_slice(bytes)?;
    ensure!(
        !input.is_empty() && input.len() <= 350,
        "invalid PDF page count"
    );
    let mut output = Extracted {
        body: String::new(),
        pages: Vec::with_capacity(input.len()),
    };
    let mut previous = 0;
    for page in input {
        ensure!(
            page.page > previous && page.page <= 350 && !page.text.is_empty(),
            "invalid PDF page"
        );
        previous = page.page;
        let start = output.body.len();
        ensure!(
            start + page.text.len() < MAX_DOCUMENT as usize,
            "PDF output exceeded text limit"
        );
        output.body.push_str(&page.text);
        output.pages.push(PageSpan {
            number: page.page,
            start,
            end: output.body.len(),
        });
        output.body.push('\n');
    }
    Ok(output)
}

#[derive(Debug, Default, Serialize)]
pub struct ContentCategories {
    pub pdf: u64,
    pub docx: u64,
    pub text: u64,
    pub images: u64,
    pub code: u64,
}

#[derive(Debug, Serialize)]
pub struct ContentSubfolder {
    pub path: String,
    pub name: String,
    pub count: u64,
    pub suggested_noise: bool,
}

#[derive(Debug, Default, Serialize)]
pub struct ContentPreview {
    pub total_files: u64,
    pub by_category: ContentCategories,
    pub top_subfolders: Vec<ContentSubfolder>,
}

const PREVIEW_SUBFOLDERS: usize = 8;
const NOISY_FOLDER_FILES: u64 = 2000;

/// Estimate what a content scope would index from the filename catalog alone.
/// Read-only, and it never stats or opens any indexed file.
pub fn preview_content_scope(
    database: &Path,
    roots: Vec<PathBuf>,
    filter: Option<ContentFilter>,
) -> Result<ContentPreview> {
    let conn = open_read(&absolute(database)?)?;
    let snapshot = conn.unchecked_transaction()?;
    let saved = crate::saved_index_scope(&snapshot)?;
    let filter = filter
        .or_else(|| saved.as_ref().map(|scope| scope.content_filter.clone()))
        .unwrap_or_default();
    let mut roots = if roots.is_empty() {
        saved
            .and_then(|scope| scope.content_roots)
            .unwrap_or_default()
    } else {
        roots
            .iter()
            .map(|root| absolute(root))
            .collect::<Result<_>>()?
    };
    roots.retain(|root| root != Path::new("/"));
    roots.sort();
    roots.dedup();
    let nested = |root: &PathBuf| {
        roots
            .iter()
            .any(|other| other != root && root.starts_with(other))
    };
    let roots: Vec<PathBuf> = roots.iter().filter(|root| !nested(root)).cloned().collect();
    let mut preview = ContentPreview::default();
    let mut folders: HashMap<PathBuf, u64> = HashMap::new();
    let mut select = snapshot.prepare(
        "SELECT path FROM item WHERE path>=?1 AND path<?2 AND kind='file'
         AND availability IN ('local','provider_metadata_only')",
    )?;
    for root in &roots {
        let Some(text) = root.to_str() else {
            continue;
        };
        let mut rows = select.query(params![format!("{text}/"), format!("{text}0")])?;
        while let Some(row) = rows.next()? {
            let path = Path::new(row.get_ref(0)?.as_str()?);
            if filter.excludes(path, &roots) {
                continue;
            }
            let Some(category) = filter.category(path) else {
                continue;
            };
            preview.total_files += 1;
            let counter = &mut preview.by_category;
            *match category {
                ContentCategory::Pdf => &mut counter.pdf,
                ContentCategory::Docx => &mut counter.docx,
                ContentCategory::Text => &mut counter.text,
                ContentCategory::Image => &mut counter.images,
                ContentCategory::Code => &mut counter.code,
            } += 1;
            let Some(parent) = path.strip_prefix(root).ok().and_then(Path::parent) else {
                continue;
            };
            let mut folder = root.clone();
            for part in parent.components().take(2) {
                folder.push(part);
                *folders.entry(folder.clone()).or_default() += 1;
            }
        }
    }
    let mut folders: Vec<_> = folders.into_iter().collect();
    folders.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    preview.top_subfolders = folders
        .into_iter()
        .take(PREVIEW_SUBFOLDERS)
        .filter_map(|(path, count)| {
            let name = path.file_name()?.to_str()?.to_owned();
            Some(ContentSubfolder {
                suggested_noise: crate::content_noise_dir(&name) || count >= NOISY_FOLDER_FILES,
                path: path.into_os_string().into_string().ok()?,
                name,
                count,
            })
        })
        .collect();
    Ok(preview)
}

pub(super) fn has_table(conn: &Connection, name: &str) -> rusqlite::Result<bool> {
    conn.prepare_cached(
        "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name=?1)",
    )?
    .query_row([name], |r| r.get(0))
}

pub(super) fn pages(conn: &Connection, id: i64) -> rusqlite::Result<Vec<PageSpan>> {
    if !has_table(conn, "pdf_page")? {
        return Ok(Vec::new());
    }
    conn.prepare_cached(
        "SELECT page,start_byte,end_byte FROM pdf_page WHERE document_id=?1 ORDER BY page",
    )?
    .query_map([id], |r| {
        Ok(PageSpan {
            number: r.get(0)?,
            start: r.get::<_, u32>(1)? as usize,
            end: r.get::<_, u32>(2)? as usize,
        })
    })?
    .collect::<rusqlite::Result<_>>()
}

pub(super) fn matching_page<'a>(
    conn: &Connection,
    id: i64,
    body: &'a str,
    words: &[impl AsRef<str>],
) -> rusqlite::Result<Option<(u32, &'a str)>> {
    for span in pages(conn, id)? {
        if let Some(page) = body.get(span.start..span.end) {
            let content = crate::norm(page);
            if words.iter().all(|word| content.contains(word.as_ref())) {
                return Ok(Some((span.number, page)));
            }
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn retry_extractor(timeout: bool) {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!(
                "lumen-content-retry-{}-{}",
                std::process::id(),
                if timeout { "timeout" } else { "permission" }
            ));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        fs::create_dir_all(&docs).unwrap();
        let database = root.join("index.db");
        let helper = root.join("extractor");
        fs::write(
            &helper,
            "#!/bin/sh\ncat >/dev/null\nprintf 'recovered document'\n",
        )
        .unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o755)).unwrap();
        fs::write(docs.join("sample.pdf"), b"%PDF-1.4\n").unwrap();
        crate::index::scan(
            &database,
            &Scope {
                roots: vec![docs.clone()],
                documents: true,
                content_roots: Some(vec![]),
                pdf_helper: Some(helper.clone()),
                ..Scope::default()
            },
        )
        .unwrap();
        apply_content_scope(&database, vec![docs], false).unwrap();
        if timeout {
            // Exercise the real extractor deadline, not a mocked error.
            fs::write(&helper, "#!/bin/sh\ncat >/dev/null\nwhile :; do :; done\n").unwrap();
        } else {
            fs::set_permissions(&helper, fs::Permissions::from_mode(0o644)).unwrap();
        }
        let failed = index_content(&database, 1).unwrap();
        assert_eq!(failed.pending, 1);
        assert_eq!(failed.indexed, 0);
        assert_eq!(failed.skipped, 1);
        let reader = open_read(&database).unwrap();
        let stamped: i64 = reader
            .query_row(
                "SELECT count(*) FROM content_job WHERE stamp IS NOT NULL",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(stamped, 0);
        drop(reader);
        fs::write(
            &helper,
            "#!/bin/sh\ncat >/dev/null\nprintf 'recovered document'\n",
        )
        .unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o755)).unwrap();
        let recovered = index_content(&database, 1).unwrap();
        assert_eq!(recovered.indexed, 1);
        assert_eq!(recovered.pending, 0);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn permission_denied_metadata_remains_pending() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!(
                "lumen-content-metadata-retry-{}",
                std::process::id()
            ));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        fs::create_dir_all(&docs).unwrap();
        fs::write(docs.join("sample.txt"), "recovered document").unwrap();
        let database = root.join("index.db");
        crate::index::scan(
            &database,
            &Scope {
                roots: vec![docs.clone()],
                ..Scope::default()
            },
        )
        .unwrap();
        apply_content_scope(&database, vec![docs.clone()], false).unwrap();
        fs::set_permissions(&docs, fs::Permissions::from_mode(0o000)).unwrap();
        let failed = index_content(&database, 1);
        fs::set_permissions(&docs, fs::Permissions::from_mode(0o755)).unwrap();
        let failed = failed.unwrap();
        assert_eq!(failed.pending, 1);
        assert_eq!(failed.skipped, 1);
        let recovered = index_content(&database, 1).unwrap();
        assert_eq!(recovered.indexed, 1);
        assert_eq!(recovered.pending, 0);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn saved_ocr_helper_paths_are_ignored_and_not_reserialized() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-content-ocr-trust-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        fs::create_dir_all(&docs).unwrap();
        fs::write(docs.join("sample.png"), b"image fixture").unwrap();
        let helper = root.join("LumenImageOcrExtractor");
        fs::write(
            &helper,
            "#!/bin/sh\ncat >/dev/null\nprintf 'untrusted OCR'\n",
        )
        .unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o755)).unwrap();
        let database = root.join("index.db");
        crate::scan(
            &database,
            &Scope {
                roots: vec![docs.clone()],
                ..Scope::default()
            },
        )
        .unwrap();
        let report =
            apply_content_scope_with_image_ocr(&database, vec![docs.clone()], false, true).unwrap();
        assert_eq!(report["content"]["pending"], 1);
        let writer = Connection::open(&database).unwrap();
        writer
            .execute(
                "UPDATE info SET value=json_set(value,'$.image_ocr_helper',?1) WHERE key='scope'",
                [helper.to_str().unwrap()],
            )
            .unwrap();
        let error = index_content(&database, 1)
            .err()
            .expect("a standalone engine cannot run OCR");
        assert!(
            error
                .to_string()
                .contains("requires the bundled LumenImageOcrExtractor")
        );
        let report =
            apply_content_scope_with_image_ocr(&database, vec![docs], false, true).unwrap();
        assert_eq!(report["content"]["pending"], 1);
        let (raw, _) = saved_scope(&writer).unwrap();
        assert!(!raw.contains("image_ocr_helper"));
        drop(writer);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn permission_denied_extraction_remains_pending() {
        retry_extractor(false);
    }

    #[test]
    fn pdf_timeout_extraction_remains_pending() {
        retry_extractor(true);
    }

    fn job_paths(database: &Path) -> Vec<String> {
        let reader = open_read(database).unwrap();
        let mut paths: Vec<String> = reader
            .prepare(
                "SELECT i.path FROM content_job j JOIN item i ON i.id=j.item_id ORDER BY i.path",
            )
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        let root = fs::canonicalize(std::env::temp_dir()).unwrap();
        for path in &mut paths {
            *path = Path::new(path.as_str())
                .strip_prefix(&root)
                .unwrap()
                .components()
                .skip(2)
                .collect::<PathBuf>()
                .to_string_lossy()
                .into_owned();
        }
        paths
    }

    fn set_mtime(path: &Path, seconds: u64) {
        fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(seconds))
            .unwrap();
    }

    #[test]
    fn content_filter_skips_noise_and_code_but_keeps_their_names() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-content-filter-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        for (name, body) in [
            ("notes.txt", "prose"),
            ("report.log", "log line"),
            ("sheets/table.csv", "a,b"),
            ("nested/deep.md", "deep"),
            ("dist/bundle.txt", "generated"),
            ("build/out.md", "generated"),
            ("Logs/run.txt", "generated"),
            ("page.ocr.txt", "ocr dump"),
            ("chat.transcript.md", "transcript"),
            ("app.min.js", "minified"),
            ("main.rs", "fn main() {}"),
            ("data.json", "{}"),
            ("tool.py", "print()"),
        ] {
            let path = docs.join(name);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, body).unwrap();
        }
        let database = root.join("index.db");
        crate::index::scan(
            &database,
            &Scope {
                roots: vec![docs.clone()],
                ..Scope::default()
            },
        )
        .unwrap();
        apply_content_scope(&database, vec![docs.clone()], false).unwrap();
        assert_eq!(
            job_paths(&database),
            [
                "nested/deep.md",
                "notes.txt",
                "report.log",
                "sheets/table.csv"
            ]
        );
        // Filename search still covers every skipped file.
        let names: i64 = open_read(&database)
            .unwrap()
            .query_row(
                "SELECT count(*) FROM item WHERE display IN ('bundle.txt','out.md','run.txt','page.ocr.txt','main.rs','app.min.js')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(names, 6);

        let code = ContentFilter {
            enable_code: true,
            ..ContentFilter::default()
        };
        apply_content_scope_with_filter(&database, vec![docs.clone()], false, false, Some(code))
            .unwrap();
        assert_eq!(
            job_paths(&database),
            [
                "data.json",
                "main.rs",
                "nested/deep.md",
                "notes.txt",
                "report.log",
                "sheets/table.csv",
                "tool.py"
            ]
        );
        // Without a filter argument the saved filter is kept.
        let kept = apply_content_scope(&database, vec![docs.clone()], false).unwrap();
        assert_eq!(kept["scope"]["content_filter"]["enable_code"], true);

        let custom = ContentFilter {
            allow_extensions: vec![".PY".into()],
            deny_extensions: vec!["log".into()],
            deny_folders: vec!["Nested".into(), docs.join("sheets").display().to_string()],
            ..ContentFilter::default()
        };
        apply_content_scope_with_filter(&database, vec![docs.clone()], false, false, Some(custom))
            .unwrap();
        assert_eq!(job_paths(&database), ["notes.txt", "tool.py"]);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn index_content_extracts_newest_documents_first_in_parallel_batches() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-content-newest-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        fs::create_dir_all(&docs).unwrap();
        for (index, name) in ["old.txt", "middle.md", "new.txt", "newest.md"]
            .into_iter()
            .enumerate()
        {
            let path = docs.join(name);
            fs::write(&path, format!("body of {name}")).unwrap();
            set_mtime(&path, 1_600_000_000 + index as u64 * 1000);
        }
        let database = root.join("index.db");
        crate::index::scan(
            &database,
            &Scope {
                roots: vec![docs.clone()],
                ..Scope::default()
            },
        )
        .unwrap();
        apply_content_scope(&database, vec![docs.clone()], false).unwrap();
        let indexed = |database: &Path| -> Vec<String> {
            open_read(database)
                .unwrap()
                .prepare(
                    "SELECT i.display FROM document d JOIN item i USING(id) ORDER BY i.mtime DESC",
                )
                .unwrap()
                .query_map([], |r| r.get(0))
                .unwrap()
                .collect::<rusqlite::Result<_>>()
                .unwrap()
        };
        let first = index_content(&database, 2).unwrap();
        assert_eq!((first.processed, first.indexed, first.pending), (2, 2, 2));
        assert_eq!(indexed(&database), ["newest.md", "new.txt"]);
        // The next run resumes after the cursor with the older documents.
        let rest = index_content(&database, 32).unwrap();
        assert_eq!((rest.indexed, rest.pending), (2, 0));
        assert_eq!(
            indexed(&database),
            ["newest.md", "new.txt", "middle.md", "old.txt"]
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn preview_content_scope_reads_only_the_catalog() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-content-preview-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let docs = root.join("docs");
        for name in [
            "a/one.pdf",
            "a/two.docx",
            "a/b/three.md",
            "c/photo.png",
            "c/main.rs",
            "dist/skip.txt",
            "top.txt",
        ] {
            let path = docs.join(name);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, "x").unwrap();
        }
        let database = root.join("index.db");
        crate::index::scan(
            &database,
            &Scope {
                roots: vec![docs.clone()],
                ..Scope::default()
            },
        )
        .unwrap();
        // Inflate one folder in the catalog only; the preview never looks on disk.
        Connection::open(&database)
            .unwrap()
            .execute(
                "INSERT INTO item(path,display,kind,availability,name,full,initials,searchable_path)
                 WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<2000)
                 SELECT ?1||'/bulk/f'||i||'.txt','f','file','local','f','f','f','f' FROM n",
                [docs.to_str().unwrap()],
            )
            .unwrap();
        fs::remove_dir_all(&docs).unwrap();
        let preview = preview_content_scope(&database, vec![docs.clone()], None).unwrap();
        let json = serde_json::to_value(&preview).unwrap();
        assert_eq!(json["total_files"], 2005);
        assert_eq!(
            json["by_category"],
            serde_json::json!({"pdf":1,"docx":1,"text":2002,"images":1,"code":0})
        );
        let folders = &json["top_subfolders"];
        assert_eq!(folders[0]["name"], "bulk");
        assert_eq!(folders[0]["count"], 2000);
        assert_eq!(folders[0]["suggested_noise"], true);
        assert_eq!(folders[0]["path"], docs.join("bulk").to_str().unwrap());
        assert_eq!(folders[1]["name"], "a");
        assert_eq!(folders[1]["count"], 3);
        assert_eq!(folders[1]["suggested_noise"], false);
        assert!(
            folders
                .as_array()
                .unwrap()
                .iter()
                .any(|folder| folder["path"] == docs.join("a/b").to_str().unwrap())
        );
        let code = preview_content_scope(
            &database,
            vec![docs.clone()],
            Some(ContentFilter {
                enable_code: true,
                enable_images: false,
                ..ContentFilter::default()
            }),
        )
        .unwrap();
        assert_eq!((code.by_category.code, code.by_category.images), (1, 0));
        fs::remove_dir_all(root).unwrap();
    }
}
