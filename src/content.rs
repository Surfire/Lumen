use crate::index::{
    Coverage, DocumentKind, document_version, extract_document, remove_document, restrict_scope,
    save_document,
};
use crate::{MAX_DOCUMENT, PdfHelperPolicy, Scope, absolute, open_read, open_write, platform};
use anyhow::{Result, ensure};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use std::{
    fs,
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
    #[cfg(target_os = "macos")]
    let _io = platform::NoMaterialization::enter()?;
    let database = absolute(database)?;
    drop(open_read(&database)?);
    let (mut conn, _lease) = open_write(&database, true)?;
    let (_, mut scope) = saved_scope(&conn)?;
    scope.documents = !roots.is_empty();
    scope.content_roots = Some(roots);
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

fn eligible_kind(coverage: &Coverage, path: &Path) -> Option<DocumentKind> {
    DocumentKind::for_path(path).filter(|kind| *kind != DocumentKind::Pdf || coverage.pdf.is_some())
}

pub(super) fn observe(
    conn: &Connection,
    coverage: &Coverage,
    id: i64,
    path: &Path,
    availability: &str,
    metadata: Option<&fs::Metadata>,
    kind: DocumentKind,
) -> Result<bool> {
    if availability != "local" {
        let job = conn.execute("DELETE FROM content_job WHERE item_id=?", [id])? != 0;
        return Ok(remove_document(conn, id)? || job);
    }
    let fetched;
    let metadata = match metadata {
        Some(meta) => Some(meta),
        None => {
            fetched = fs::symlink_metadata(path).ok();
            fetched.as_ref()
        }
    };
    let version = metadata
        .filter(|meta| meta.is_file() && platform::availability(path, meta) == "local")
        .map(|meta| document_version(coverage, kind, meta));
    let stale: bool = conn
        .prepare_cached(
            "SELECT EXISTS(SELECT 1 FROM document_state WHERE id=?1 AND stamp IS NOT ?2)",
        )?
        .query_row(params![id, version], |r| r.get(0))?;
    if stale {
        remove_document(conn, id)?;
    }
    let changed = conn
        .prepare_cached(
            "INSERT INTO content_job(item_id) VALUES(?1)
        ON CONFLICT(item_id) DO UPDATE SET stamp=NULL WHERE stamp IS NOT NULL AND stamp IS NOT ?2",
        )?
        .execute(params![id, version])?
        != 0;
    Ok(stale || changed)
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
    let mut batch = ContentBatch::default();
    let started = std::time::Instant::now();
    let candidates = conn
        .prepare(
            "SELECT i.id,i.path FROM content_job j JOIN item i ON i.id=j.item_id
        WHERE j.stamp IS NULL AND i.availability='local' ORDER BY j.item_id LIMIT ?1",
        )?
        .query_map([max.clamp(1, 32) as i64], |r| {
            Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for (id, path) in candidates {
        if started.elapsed() > std::time::Duration::from_secs(2) && batch.processed > 0 {
            break;
        }
        let file = Path::new(&path);
        if saved_scope(&conn)?.0 != scope_identity {
            break;
        }
        let kind = eligible_kind(&configured, file).filter(|_| configured.permits_content(file));
        let version =
            |kind| local_metadata(file).map(|meta| document_version(&configured, kind, &meta));
        let before = kind.and_then(version);
        let cached = conn
            .query_row("SELECT stamp FROM document_state WHERE id=?", [id], |r| {
                r.get::<_, String>(0)
            })
            .optional()?;
        let unchanged = before.is_some() && before == cached;
        let extracted = if unchanged {
            None
        } else {
            kind.filter(|_| before.is_some())
                .and_then(|kind| extract_document(&configured, file, kind).ok())
                .filter(|item| !item.body.trim().is_empty())
        };
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if saved_scope(&tx)?.0 != scope_identity {
            break;
        }
        let pending: bool = tx
            .prepare_cached(
                "SELECT EXISTS(SELECT 1 FROM content_job j JOIN item i ON i.id=j.item_id
            WHERE i.id=?1 AND i.path=?2 AND i.availability='local' AND j.stamp IS NULL)",
            )?
            .query_row(params![id, path], |r| r.get(0))?;
        if !pending || before != kind.and_then(version) {
            continue;
        }
        if kind.is_none() {
            tx.execute("DELETE FROM content_job WHERE item_id=?", [id])?;
            remove_document(&tx, id)?;
        } else {
            if let (Some(version), Some(extracted)) = (&before, extracted) {
                save_document(&tx, id, version, &extracted)?;
                batch.indexed += 1;
            } else if !unchanged {
                remove_document(&tx, id)?;
            }
            tx.execute(
                "UPDATE content_job SET stamp=?2 WHERE item_id=?1",
                params![id, before.as_deref().unwrap_or("unavailable")],
            )?;
        }
        tx.commit()?;
        batch.processed += 1;
    }
    batch.pending = coverage(&conn)?.pending;
    Ok(batch)
}

fn local_metadata(path: &Path) -> Option<fs::Metadata> {
    // Check ancestors in root order before examining any child. Opening document
    // bytes repeats the engine's no-follow and no-materialization protections.
    let parents: Vec<_> = path.ancestors().skip(1).collect();
    for parent in parents.into_iter().rev() {
        let meta = fs::symlink_metadata(parent).ok()?;
        if !meta.is_dir() || platform::availability(parent, &meta) == "placeholder" {
            return None;
        }
    }
    let meta = fs::symlink_metadata(path).ok()?;
    (meta.is_file() && platform::availability(path, &meta) == "local").then_some(meta)
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
