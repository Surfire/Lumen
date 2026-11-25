use crate::index::{
    Coverage, DocumentKind, ImageOcrExtractor, can_open_document, check_document_access,
    document_version, extract_document, remove_document, restrict_scope, save_document,
};
use crate::{MAX_DOCUMENT, PdfHelperPolicy, Scope, absolute, open_read, open_write, platform};
use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use std::{
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
    #[cfg(target_os = "macos")]
    let _io = platform::NoMaterialization::enter()?;
    let database = absolute(database)?;
    drop(open_read(&database)?);
    let (mut conn, _lease) = open_write(&database, true)?;
    let (_, mut scope) = saved_scope(&conn)?;
    scope.documents = !roots.is_empty();
    scope.content_roots = Some(roots);
    scope.image_ocr = image_ocr;
    scope.pdf_helper = if scope.documents && !bundled_pdf {
        scope.pdf_helper
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
    let coverage = Coverage::new(database, &scope)?;
    restrict_scope(&mut conn, &coverage)?;
    let mut report = crate::status(&conn)?;
    report["scope"] = serde_json::json!({
        "roots": coverage.scope.roots, "allow": coverage.scope.allow, "deny": coverage.scope.deny,
        "documents": coverage.scope.documents, "content_roots": coverage.scope.content_roots,
        "image_ocr": coverage.scope.image_ocr,
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
            if !coverage.permits_content(path) || eligible_kind(coverage, path).is_none() {
                ids.push(row.get(0)?);
            }
        }
        Ok(ids)
    }
    for id in retired(
        conn,
        coverage,
        "SELECT i.id,i.path FROM document d JOIN item i USING(id)",
    )? {
        remove_document(conn, id)?;
    }
    for id in retired(
        conn,
        coverage,
        "SELECT i.id,i.path FROM content_job j JOIN item i ON i.id=j.item_id",
    )? {
        conn.prepare_cached("DELETE FROM content_job WHERE item_id=?")?
            .execute([id])?;
    }
    if let Some(roots) = &coverage.scope.content_roots {
        let mut select = conn.prepare("SELECT id,path FROM item WHERE path>=?1 AND path<?2 AND kind='file' AND availability='local'")?;
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
    DocumentKind::for_path(path).filter(|kind| match kind {
        DocumentKind::Pdf => coverage.pdf.is_some(),
        DocumentKind::Image => coverage.scope.image_ocr,
        _ => true,
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
    let stale: bool = conn
        .prepare_cached(
            "SELECT EXISTS(SELECT 1 FROM document d LEFT JOIN document_state s USING(id)
             WHERE d.id=?1 AND (?2 IS NULL OR s.stamp IS NOT ?2))",
        )?
        .query_row(params![id, verified_version], |r| r.get(0))?;
    if stale {
        remove_document(conn, id)?;
    }
    let changed = conn
        .prepare_cached(
            "INSERT INTO content_job(item_id) VALUES(?1)
             ON CONFLICT(item_id) DO UPDATE SET stamp=NULL
             WHERE stamp IS NOT NULL AND (?3 OR stamp IS NOT ?2)",
        )?
        .execute(params![id, version, stale])?
        != 0;
    Ok(stale || changed)
}

pub(super) fn retire(conn: &Connection, id: i64) -> Result<bool> {
    let job = conn
        .prepare_cached("DELETE FROM content_job WHERE item_id=?")?
        .execute([id])?
        != 0;
    Ok(remove_document(conn, id)? || job)
}

#[derive(Default, Serialize)]
pub struct ContentBatch {
    pub processed: usize,
    pub indexed: usize,
    pub pending: i64,
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
    Ok(conn.query_row(
        "SELECT count(*)-count(j.stamp),count(j.stamp),count(*)
        FROM content_job j JOIN item i ON i.id=j.item_id WHERE i.availability='local'",
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
    let (cursor, upper): (i64, i64) = conn.query_row(
        "SELECT coalesce((SELECT CAST(value AS INTEGER) FROM info WHERE key='content_cursor'),0),
                coalesce((SELECT max(item_id) FROM content_job),0)",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    let mut attempted = false;
    // Wrap once, and never try the same pending job twice in this invocation.
    // Only completed jobs count toward --max; skip fast failures until the
    // time budget expires, then resume after the last attempt on the next run.
    'batch: for (mut after, end) in [(cursor, upper), (0, cursor.min(upper))] {
        loop {
            if batch.processed >= max.clamp(1, 32)
                || (attempted && started.elapsed() >= std::time::Duration::from_secs(2))
                || saved_scope(&conn)?.0 != scope_identity
            {
                break 'batch;
            }
            let Some((id, path)) = conn
                .prepare_cached(
                    "SELECT i.id,i.path FROM content_job j JOIN item i ON i.id=j.item_id
                     WHERE j.stamp IS NULL AND i.availability='local'
                       AND j.item_id>?1 AND j.item_id<=?2 ORDER BY j.item_id LIMIT 1",
                )?
                .query_row(params![after, end], |r| {
                    Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
                })
                .optional()?
            else {
                break;
            };
            conn.prepare_cached(
                "INSERT INTO info(key,value) VALUES('content_cursor',?1)
                 ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            )?
            .execute([id])?;
            attempted = true;
            after = id;
            // Both metadata passes and extraction must finish before acquiring the
            // SQLite write lock. Recheck the database scope and job under that lock.
            let update =
                match prepare_update(&conn, &configured, ocr.as_ref(), id, Path::new(&path)) {
                    Ok(Some(update)) => update,
                    Ok(None) => continue,
                    Err(error) if has_io_error(&error, ErrorKind::PermissionDenied) => {
                        Update::Denied
                    }
                    Err(error) => return Err(error),
                };
            let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
            if saved_scope(&tx)?.0 != scope_identity {
                break 'batch;
            }
            let pending: bool = tx
                .prepare_cached(
                    "SELECT EXISTS(SELECT 1 FROM content_job j JOIN item i ON i.id=j.item_id
            WHERE i.id=?1 AND i.path=?2 AND i.availability='local' AND j.stamp IS NULL)",
                )?
                .query_row(params![id, path], |r| r.get(0))?;
            if !pending {
                continue;
            }
            match update {
                Update::Denied => {
                    // A job seeded from the legacy index may still have a body.
                    // Clear it now, but keep the job pending for a later retry.
                    remove_document(&tx, id)?;
                    tx.commit()?;
                    continue;
                }
                Update::Retire => {
                    retire(&tx, id)?;
                }
                Update::Complete {
                    version,
                    unchanged,
                    extracted,
                } => {
                    if let (Some(version), Some(extracted)) = (&version, extracted) {
                        save_document(&tx, id, version, &extracted)?;
                        batch.indexed += 1;
                    } else if !unchanged {
                        remove_document(&tx, id)?;
                    }
                    tx.execute(
                        "UPDATE content_job SET stamp=?2 WHERE item_id=?1",
                        params![id, version.as_deref().unwrap_or("unavailable")],
                    )?;
                }
            }
            tx.commit()?;
            batch.processed += 1;
        }
    }
    batch.pending = coverage(&conn)?.pending;
    Ok(batch)
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
    conn: &Connection,
    coverage: &Coverage,
    ocr: Option<&ImageOcrExtractor>,
    id: i64,
    path: &Path,
) -> Result<Option<Update>> {
    let Some(kind) = eligible_kind(coverage, path).filter(|_| coverage.permits_content(path))
    else {
        return Ok(Some(Update::Retire));
    };
    let metadata = || match local_metadata(path) {
        Err(error) if error.kind() != ErrorKind::PermissionDenied => Ok(None),
        result => result,
    };
    let stamp = |meta: &fs::Metadata| document_version(coverage, kind, meta);
    let before = metadata()?;
    let version = before.as_ref().map(stamp);
    let cached = conn
        .query_row("SELECT stamp FROM document_state WHERE id=?", [id], |r| {
            r.get::<_, String>(0)
        })
        .optional()?;
    let unchanged = if let Some(meta) = before.as_ref().filter(|_| version == cached) {
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
            _ => extract_document(coverage, path, kind),
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

fn local_metadata(path: &Path) -> io::Result<Option<fs::Metadata>> {
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
    Ok((meta.is_file() && platform::availability(path, &meta) == "local").then_some(meta))
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
        assert_eq!(failed.unwrap().pending, 1);
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
}
