use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand, ValueEnum};
use lumen::{BgeModel, GemmaModel, Mode, Model, ModelBackend, PdfHelperPolicy, Scope};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    io::{self, BufRead, Write},
    path::PathBuf,
};

#[derive(Parser)]
#[command(version, about = "Lumen — local search / 本地搜索")]
struct Cli {
    #[arg(long, global = true)]
    db: Option<PathBuf>,
    #[command(subcommand)]
    command: Action,
}
#[derive(Clone, Copy, ValueEnum)]
enum SearchMode {
    Name,
    Text,
    Semantic,
    All,
}
impl From<SearchMode> for Mode {
    fn from(x: SearchMode) -> Self {
        match x {
            SearchMode::Name => Self::Name,
            SearchMode::Text => Self::Text,
            SearchMode::Semantic => Self::Semantic,
            SearchMode::All => Self::All,
        }
    }
}
#[derive(Args)]
struct ScopeArgs {
    /// Send scan progress as JSON lines to stderr.
    #[arg(long)]
    progress: bool,
    #[arg(long)]
    root: Vec<PathBuf>,
    #[arg(long)]
    allow: Vec<PathBuf>,
    #[arg(long)]
    deny: Vec<PathBuf>,
    #[arg(long)]
    documents: bool,
    /// Authorize document indexing only below this directory (repeatable).
    #[arg(long)]
    content_root: Vec<PathBuf>,
    /// Recognize text in local images in the selected content folders (requires the app helper).
    #[arg(long, requires = "content_root")]
    image_ocr: bool,
    /// Keep an explicit content selection, including an empty selection.
    #[arg(long)]
    separate_content: bool,
    #[arg(long, requires = "documents")]
    pdf_helper: Option<PathBuf>,
    /// Use this app bundle's PDF extractor and its stable extraction format.
    #[arg(long, conflicts_with = "pdf_helper")]
    bundled_pdf_helper: bool,
}

impl From<ScopeArgs> for Scope {
    fn from(args: ScopeArgs) -> Self {
        let pdf_helper_policy = if args.bundled_pdf_helper {
            Some(PdfHelperPolicy::Bundled)
        } else {
            args.pdf_helper.as_ref().map(|_| PdfHelperPolicy::Manual)
        };
        let content_roots =
            (args.separate_content || !args.content_root.is_empty()).then_some(args.content_root);
        let documents = content_roots
            .as_ref()
            .map_or(args.documents, |roots| !roots.is_empty());
        Self {
            roots: args.root,
            allow: args.allow,
            deny: args.deny,
            documents,
            content_roots,
            pdf_helper: args.pdf_helper,
            pdf_helper_policy,
            image_ocr: args.image_ocr,
            image_ocr_helper: None,
        }
    }
}

#[derive(Args)]
struct SemanticArgs {
    /// Select EmbeddingGemma 2 explicitly, including a partially built index for a diagnostic query.
    #[arg(long, conflicts_with_all = ["helper", "bge", "language"])]
    gemma: bool,
    /// Override the isolated EmbeddingGemma 2 resource directory.
    #[arg(long, conflicts_with_all = ["helper", "bge", "language"], value_name = "DIR")]
    gemma_home: Option<PathBuf>,
    /// Existing local model executable, or the BGE worker script with --bge-model.
    #[arg(long)]
    helper: Option<PathBuf>,
    /// Use the installed experimental BGE candidate backend.
    #[arg(long, conflicts_with = "helper")]
    bge: bool,
    /// Override the isolated installed BGE resource directory.
    #[arg(long, requires = "bge", value_name = "DIR")]
    bge_home: Option<PathBuf>,
    /// Language profile (defaults to en for a legacy helper and zh for BGE).
    #[arg(long)]
    language: Option<String>,
    /// Verified local BGE snapshot for experimental semantic candidate retrieval.
    #[arg(long, requires_all = ["helper", "bge_python"], value_name = "DIR")]
    bge_model: Option<PathBuf>,
    /// Isolated Python executable with local BGE dependencies already available.
    #[arg(long, requires = "bge_model", value_name = "PATH")]
    bge_python: Option<PathBuf>,
}

enum ConfiguredModel {
    Helper(Model),
    Bge(BgeModel),
    Gemma(GemmaModel),
}

impl SemanticArgs {
    fn configure(self) -> Result<Option<ConfiguredModel>> {
        if self.gemma {
            return Ok(Some(ConfiguredModel::Gemma(GemmaModel::installed(
                self.gemma_home.as_deref(),
            )?)));
        }
        if self.bge {
            let model = BgeModel::installed(
                self.bge_home.as_deref(),
                self.language.as_deref().unwrap_or("zh"),
            )?;
            model.check_installed_files()?;
            return Ok(Some(ConfiguredModel::Bge(model)));
        }
        let model = match (self.helper, self.bge_model, self.bge_python) {
            (Some(helper), Some(directory), Some(python)) => ConfiguredModel::Bge(BgeModel {
                directory,
                python,
                helper,
                language: self.language.unwrap_or_else(|| "zh".into()),
            }),
            (Some(executable), None, None) => ConfiguredModel::Helper(Model {
                executable,
                language: self.language.unwrap_or_else(|| "en".into()),
            }),
            (None, None, None) => return Ok(None),
            _ => anyhow::bail!(
                "the optional BGE backend requires --helper, --bge-model and --bge-python"
            ),
        };
        Ok(Some(model))
    }
}

impl ConfiguredModel {
    fn backend(&self) -> ModelBackend<'_> {
        match self {
            Self::Helper(model) => ModelBackend::Helper(model),
            Self::Bge(model) => ModelBackend::Bge(model),
            Self::Gemma(model) => ModelBackend::Gemma(model),
        }
    }
}

#[derive(Subcommand)]
enum Action {
    /// Index the readable startup volume by default, or explicit roots. Metadata only unless --documents.
    Index(ScopeArgs),
    /// Reconcile and maintain an index. Emits JSON ready and updated events. Diagnostics go to stderr.
    Watch {
        #[command(flatten)]
        scope: ScopeArgs,
        /// Allow early cached lookup for a client checking each hit with --check-access.
        #[arg(long)]
        cached_start: bool,
    },
    /// Query a saved index; never implicitly rebuild it.
    Query {
        text: String,
        #[arg(long, value_enum, default_value = "name")]
        mode: SearchMode,
        #[arg(long, default_value_t = 20)]
        limit: usize,
        /// Check live access before returning any cached result.
        #[arg(long)]
        check_access: bool,
        #[command(flatten)]
        semantic: SemanticArgs,
    },
    /// Confirm a previously presented hit by exact path without repeating search.
    ValidateHit {
        #[arg(long)]
        kind: String,
        #[arg(long)]
        availability: String,
        #[arg(long)]
        document_stamp: Option<String>,
        path: PathBuf,
    },
    /// Apply an explicit document scope without rebuilding the filename catalog.
    ContentScope {
        #[arg(long)]
        content_root: Vec<PathBuf>,
        #[arg(long)]
        bundled_pdf_helper: bool,
        /// Also index text in local images using the app's Apple Vision helper.
        #[arg(long, requires = "content_root")]
        image_ocr: bool,
    },
    /// Extract a resumable batch from the saved document scope.
    Content {
        #[arg(long, default_value_t = 8)]
        max: usize,
    },
    /// Opt one local folder into image content indexing, or clear its image vectors.
    ImageScope {
        #[arg(required_unless_present = "clear")]
        root: Option<PathBuf>,
        #[arg(long, conflicts_with = "root")]
        clear: bool,
    },
    /// Read the saved image folder and stored vector count.
    ImageStatus,
    /// Embed the next bounded batch from the opted-in image folder.
    ImageIndex {
        #[arg(long, value_name = "FILE")]
        projector: PathBuf,
        #[arg(long, value_name = "DIR")]
        gemma_home: Option<PathBuf>,
        #[arg(long, value_name = "CURSOR")]
        after: Option<String>,
        #[arg(long, default_value_t = 8)]
        max: usize,
    },
    /// Serve local text-to-image candidate searches over newline-delimited JSON.
    ImageServe {
        #[arg(long, value_name = "FILE")]
        projector: PathBuf,
        #[arg(long, value_name = "DIR")]
        gemma_home: Option<PathBuf>,
        #[arg(long)]
        check_access: bool,
    },
    /// List eligible attached external volumes and saved availability.
    Volumes,
    /// Explicitly index names from one mounted local external volume.
    IndexVolume {
        /// Emit progress reports as JSON lines on stderr.
        #[arg(long)]
        progress: bool,
        /// Verify that this is still the volume selected by the client.
        #[arg(long)]
        uuid: Option<String>,
        path: PathBuf,
    },
    /// Remove an external volume catalog and its authorization.
    ForgetVolume { uuid: String },
    /// Explain one explicitly selected path using only metadata and the saved index.
    Diagnose { path: PathBuf },
    /// Embed the next batch of document chunks locally (defaults to Gemma).
    Embed {
        #[command(flatten)]
        semantic: SemanticArgs,
        /// Maximum number of encodable chunks to process in this batch.
        #[arg(long, default_value_t = 32)]
        max: usize,
    },
    /// Check installed local semantic resources without modifying the index.
    ModelStatus {
        #[arg(long, conflicts_with = "bge_home")]
        gemma: bool,
        #[arg(long, requires = "gemma", value_name = "DIR")]
        gemma_home: Option<PathBuf>,
        #[arg(long, default_value = "zh")]
        language: String,
        #[arg(long, value_name = "DIR")]
        bge_home: Option<PathBuf>,
        /// Launch the worker and check pinned hashes, runtime and model format.
        #[arg(long)]
        verify: bool,
    },
    /// Check whether Gemma has indexed the opted-in document scope and is ready for the launcher.
    GemmaStatus {
        #[arg(long, value_name = "DIR")]
        gemma_home: Option<PathBuf>,
        /// Run a local bilingual retrieval health check before reporting ready.
        #[arg(long)]
        verify: bool,
    },
    /// Reuse a verified Gemma worker for newline-delimited JSON semantic queries on stdio.
    SemanticServe {
        #[arg(long, value_name = "DIR")]
        gemma_home: Option<PathBuf>,
        #[arg(long)]
        check_access: bool,
    },
    /// Report scan coverage and embedding counts.
    Status {
        /// Include the saved absolute directory rules and document setting.
        #[arg(long)]
        include_scope: bool,
    },
    /// Persistent newline-delimited JSON query transport on stdio for the desktop launcher.
    Serve {
        #[arg(long)]
        check_access: bool,
    },
}
#[derive(Deserialize)]
struct Request {
    id: u64,
    query: String,
    limit: Option<usize>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ServeOperation {
    #[default]
    Search,
    Validate,
}

#[derive(Deserialize)]
struct ServeRequest {
    id: u64,
    #[serde(default)]
    op: ServeOperation,
    query: Option<String>,
    #[serde(default)]
    mode: Mode,
    limit: Option<usize>,
    check_access: Option<bool>,
    hits: Option<Vec<ValidationHit>>,
}

#[derive(Deserialize)]
struct ValidationHit {
    path: String,
    kind: String,
    availability: String,
    document_stamp: Option<String>,
}

#[derive(Serialize)]
struct SearchReply {
    id: u64,
    hits: Vec<lumen::Hit>,
}

// Access checks can discard stale cached hits. Fetch candidates before applying
// the client's limit, while respecting each search engine's existing bound.
fn search_checked(
    limit: usize,
    check_access: bool,
    maximum: usize,
    search: impl FnOnce(usize) -> Result<Vec<lumen::Hit>>,
) -> Result<Vec<lumen::Hit>> {
    let requested = limit.clamp(1, maximum);
    let fetch = if check_access {
        requested.saturating_mul(4).min(100)
    } else {
        limit
    };
    let mut hits = search(fetch)?;
    if check_access {
        lumen::verify_cached_access(&mut hits);
        hits.truncate(requested);
    }
    Ok(hits)
}

fn scan_progress(enabled: bool) -> io::Result<Option<lumen::ScanProgressReporter>> {
    enabled
        .then(|| {
            lumen::ScanProgressReporter::start(|event| {
                let mut err = io::stderr().lock();
                serde_json::to_writer(&mut err, &event)?;
                writeln!(err)?;
                err.flush()
            })
        })
        .transpose()
}

fn gemma_status(
    inspection: Result<()>,
    verify: bool,
    coverage: Option<lumen::GemmaCoverage>,
) -> serde_json::Value {
    let available = inspection.is_ok();
    let verified = verify && available;
    let ready = verified
        && coverage
            .as_ref()
            .is_some_and(lumen::GemmaCoverage::searchable);
    json!({
        "backend": "gemma_candidate",
        "model_id": lumen::GEMMA_MODEL_ID,
        "available": available,
        "verified": verified,
        "ready": ready,
        "coverage": coverage,
        "diagnostic": inspection.err().map(|error| format!("{error:#}")),
    })
}

const REQUEST_LINE_LIMIT: u64 = 16 * 1024;

#[derive(Serialize)]
struct ValidationReply {
    id: u64,
    valid: Vec<bool>,
}

#[derive(Serialize)]
#[serde(untagged)]
enum ServeReply {
    Search(SearchReply),
    Validate(ValidationReply),
}

fn serve(
    mut input: impl BufRead,
    mut output: impl Write,
    session: &mut lumen::SearchSession,
    check_access: bool,
) -> Result<()> {
    let mut line = Vec::new();
    loop {
        line.clear();
        if std::io::Read::take(&mut input, REQUEST_LINE_LIMIT + 1).read_until(b'\n', &mut line)?
            == 0
        {
            return Ok(());
        }
        anyhow::ensure!(
            line.len() as u64 <= REQUEST_LINE_LIMIT && line.ends_with(b"\n"),
            "invalid serve request frame"
        );
        match serde_json::from_slice::<ServeRequest>(&line) {
            Ok(q) => {
                let result = match q.op {
                    ServeOperation::Search => (|| -> Result<ServeReply> {
                        let query = q.query.context("search requires query")?;
                        let hits = search_checked(
                            q.limit.unwrap_or(20),
                            q.check_access.unwrap_or(check_access),
                            100,
                            |limit| session.search(&query, q.mode, limit),
                        )?;
                        Ok(ServeReply::Search(SearchReply { id: q.id, hits }))
                    })(),
                    ServeOperation::Validate => (|| -> Result<ServeReply> {
                        let hits = q.hits.context("validate requires hits")?;
                        let hits: Vec<_> = hits
                            .iter()
                            .map(|hit| {
                                (
                                    hit.path.as_str(),
                                    hit.kind.as_str(),
                                    hit.availability.as_str(),
                                    hit.document_stamp.as_deref(),
                                )
                            })
                            .collect();
                        Ok(ServeReply::Validate(ValidationReply {
                            id: q.id,
                            valid: session.validate(&hits),
                        }))
                    })(),
                };
                match result {
                    Ok(reply) => serde_json::to_writer(&mut output, &reply)?,
                    Err(error) => serde_json::to_writer(
                        &mut output,
                        &json!({"id":q.id,"error":error.to_string()}),
                    )?,
                }
            }
            Err(error) => serde_json::to_writer(&mut output, &json!({"error":error.to_string()}))?,
        }
        writeln!(output)?;
        output.flush()?;
    }
}

fn serve_gemma(
    mut input: impl BufRead,
    mut output: impl Write,
    mut search: impl FnMut(&str, usize) -> Result<Vec<lumen::Hit>>,
) -> Result<()> {
    let mut line = Vec::new();
    loop {
        line.clear();
        if std::io::Read::take(&mut input, REQUEST_LINE_LIMIT + 1).read_until(b'\n', &mut line)?
            == 0
        {
            return Ok(());
        }
        anyhow::ensure!(
            line.len() as u64 <= REQUEST_LINE_LIMIT && line.ends_with(b"\n"),
            "invalid semantic request frame"
        );
        match serde_json::from_slice::<Request>(&line) {
            Ok(q) => match search(&q.query, q.limit.unwrap_or(20)) {
                Ok(hits) => serde_json::to_writer(&mut output, &SearchReply { id: q.id, hits })?,
                Err(error) => serde_json::to_writer(
                    &mut output,
                    &json!({"id":q.id,"error":error.to_string()}),
                )?,
            },
            Err(error) => serde_json::to_writer(&mut output, &json!({"error":error.to_string()}))?,
        }
        writeln!(output)?;
        output.flush()?;
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let db = cli.db.unwrap_or_else(lumen::standard_database);
    match cli.command {
        Action::Index(args) => {
            let progress = scan_progress(args.progress)?;
            let stats = lumen::scan_with_progress(&db, &args.into(), progress.as_ref())?;
            drop(progress);
            println!("{}", serde_json::to_string_pretty(&stats)?);
        }
        Action::Watch {
            scope,
            cached_start,
        } => {
            let progress = scan_progress(scope.progress)?;
            lumen::watch_with_launch_progress(
                &db,
                &scope.into(),
                progress.as_ref(),
                cached_start,
                |event| {
                    let mut out = io::stdout().lock();
                    serde_json::to_writer(&mut out, &event)?;
                    writeln!(out)?;
                    out.flush()?;
                    Ok(())
                },
            )?;
        }
        Action::Query {
            text,
            mode,
            limit,
            check_access,
            semantic,
        } => {
            let permits_semantic = lumen::query_allows_semantic(&text);
            if matches!(mode, SearchMode::Semantic) && !permits_semantic {
                println!("[]");
                return Ok(());
            }
            let gemma_home = semantic.gemma_home.clone();
            let model = permits_semantic
                .then(|| semantic.configure())
                .transpose()?
                .flatten();
            let hits = search_checked(limit, check_access, 100, |limit| {
                Ok(if model.is_none() && matches!(mode, SearchMode::Semantic) {
                    lumen::GemmaSearchSession::open(
                        &db,
                        &GemmaModel::installed(gemma_home.as_deref())?,
                    )?
                    .search(&text, limit)?
                } else {
                    let conn =
                        lumen::open_read(&db).context("no usable index; run lumen index first")?;
                    lumen::search_with_backend(
                        &conn,
                        &text,
                        mode.into(),
                        limit,
                        model.as_ref().map(ConfiguredModel::backend),
                    )?
                })
            })?;
            println!("{}", serde_json::to_string_pretty(&hits)?);
        }
        Action::ValidateHit {
            path,
            kind,
            availability,
            document_stamp,
        } => {
            let valid =
                lumen::validate_hit(&db, &path, &kind, &availability, document_stamp.as_deref());
            println!("{}", json!({"valid":valid}));
        }
        Action::ContentScope {
            content_root,
            bundled_pdf_helper,
            image_ocr,
        } => {
            println!(
                "{}",
                lumen::apply_content_scope_with_image_ocr(
                    &db,
                    content_root,
                    bundled_pdf_helper,
                    image_ocr
                )?
            );
        }
        Action::Content { max } => {
            // Only this short-lived worker and its extractor children run at low priority.
            unsafe { libc::setpriority(libc::PRIO_PROCESS, 0, 10) };
            println!(
                "{}",
                serde_json::to_string(&lumen::index_content(&db, max)?)?
            );
        }
        Action::Volumes => println!("{}", serde_json::to_string(&lumen::volumes(&db))?),
        Action::IndexVolume {
            path,
            progress,
            uuid,
        } => {
            let progress = scan_progress(progress)?;
            let stats = lumen::index_volume(&db, &path, uuid.as_deref(), progress.as_ref())?;
            drop(progress);
            println!("{}", serde_json::to_string(&stats)?);
        }
        Action::ForgetVolume { uuid } => {
            println!("{}", json!({"removed":lumen::forget_volume(&db, &uuid)?}));
        }
        Action::Diagnose { path } => {
            println!("{}", serde_json::to_string(&lumen::diagnose(&db, &path))?);
        }
        Action::Embed { semantic, max } => {
            let gemma_home = semantic.gemma_home.clone();
            let model = match semantic.configure()? {
                Some(model) => model,
                None => ConfiguredModel::Gemma(GemmaModel::installed(gemma_home.as_deref())?),
            };
            println!(
                "{}",
                serde_json::to_string(&lumen::embed_batch(&db, model.backend(), max)?)?
            );
        }
        Action::ModelStatus {
            gemma: true,
            gemma_home,
            verify,
            ..
        } => {
            let inspection = GemmaModel::installed(gemma_home.as_deref())
                .and_then(|model| model.inspect(verify));
            println!("{}", gemma_status(inspection, verify, None));
        }
        Action::GemmaStatus { gemma_home, verify } => {
            let conn = lumen::open_read(&db)?;
            let inspection = GemmaModel::installed(gemma_home.as_deref())
                .and_then(|model| model.inspect(verify));
            let coverage = lumen::gemma_coverage(&conn)?;
            println!("{}", gemma_status(inspection, verify, Some(coverage)));
        }
        Action::ImageScope { root, clear: _ } => {
            println!(
                "{}",
                serde_json::to_string(&lumen::image_scope(&db, root.as_deref())?)?
            );
        }
        Action::ImageStatus => {
            println!("{}", serde_json::to_string(&lumen::image_status(&db)?)?);
        }
        Action::ImageIndex {
            projector,
            gemma_home,
            after,
            max,
        } => {
            let model = GemmaModel::installed(gemma_home.as_deref())?;
            println!(
                "{}",
                serde_json::to_string(&lumen::image_batch(
                    &db,
                    &model,
                    &projector,
                    after.as_deref(),
                    max
                )?)?
            );
        }
        Action::ImageServe {
            projector,
            gemma_home,
            check_access,
        } => {
            let model = GemmaModel::installed(gemma_home.as_deref())?;
            let mut session = lumen::ImageSearchSession::open(&db, &model, projector)?;
            serve_gemma(
                io::stdin().lock(),
                io::BufWriter::new(io::stdout().lock()),
                |query, limit| {
                    search_checked(limit, check_access, 20, |limit| {
                        if check_access {
                            session.search_candidates(query, limit)
                        } else {
                            session.search(query, limit)
                        }
                    })
                },
            )?;
        }
        Action::SemanticServe {
            gemma_home,
            check_access,
        } => {
            let mut session = lumen::GemmaSearchSession::open(
                &db,
                &GemmaModel::installed(gemma_home.as_deref())?,
            )?;
            serve_gemma(
                io::stdin().lock(),
                io::BufWriter::new(io::stdout().lock()),
                |query, limit| {
                    search_checked(limit, check_access, 100, |limit| {
                        session.search(query, limit)
                    })
                },
            )?;
        }
        Action::ModelStatus {
            language,
            gemma: false,
            gemma_home: _,
            bge_home,
            verify,
        } => {
            let model = BgeModel::installed(bge_home.as_deref(), &language)?;
            let inspection = if verify {
                model.verify()
            } else {
                model.check_installed_files()
            };
            let available = inspection.is_ok();
            println!(
                "{}",
                json!({
                    "backend": "bge_candidate",
                    "language": model.language,
                    "available": available,
                    "verified": verify && available,
                    "diagnostic": inspection.err().map(|error| format!("{error:#}")),
                })
            );
        }
        Action::Status { include_scope } => {
            let conn = lumen::open_read(&db)?;
            let mut report = lumen::status(&conn)?;
            if include_scope && let Some(scope) = lumen::saved_index_scope(&conn)? {
                report["scope"] = json!({
                    "roots": scope.roots,
                    "allow": scope.allow,
                    "deny": scope.deny,
                    "documents": scope.documents,
                    "content_roots": scope.content_roots,
                });
            }
            println!("{}", serde_json::to_string_pretty(&report)?);
        }
        Action::Serve { check_access } => {
            let mut search = lumen::SearchSession::open(&db)
                .context("no usable index; run lumen index first")?;
            serve(
                io::stdin().lock(),
                io::BufWriter::new(io::stdout().lock()),
                &mut search,
                check_access,
            )?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[cfg(target_os = "macos")]
    #[test]
    fn checked_search_fills_limit_after_discarding_stale_candidates() {
        use std::{
            ffi::{CStr, OsStr},
            fs,
            os::unix::ffi::OsStrExt,
            path::PathBuf,
        };
        let mut template = *b"/tmp/lumen-overfetch-XXXXXX\0";
        let path = unsafe { libc::mkdtemp(template.as_mut_ptr().cast()) };
        assert!(!path.is_null());
        let dir = PathBuf::from(OsStr::from_bytes(
            unsafe { CStr::from_ptr(path) }.to_bytes(),
        ));
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(dir.clone());
        let root = dir.join("root");
        fs::create_dir(&root).unwrap();
        for name in ["match-a.txt", "match-b.txt", "match-c.txt", "match-d.txt"] {
            fs::write(root.join(name), "candidate").unwrap();
        }
        let db = dir.join("index.sqlite");
        lumen::scan(
            &db,
            &lumen::Scope {
                roots: vec![root],
                ..lumen::Scope::default()
            },
        )
        .unwrap();
        let mut session = lumen::SearchSession::open(&db).unwrap();
        let candidates = session.search("match", Mode::Name, 4).unwrap();
        assert_eq!(candidates.len(), 4);
        fs::remove_file(&candidates[0].path).unwrap();
        let hits = search_checked(2, true, 100, |limit| {
            session.search("match", Mode::Name, limit)
        })
        .unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].path, candidates[1].path);
        assert_eq!(hits[1].path, candidates[2].path);
        let unchecked = search_checked(2, false, 100, |limit| {
            session.search("match", Mode::Name, limit)
        })
        .unwrap();
        assert_eq!(unchecked.len(), 2);
        assert_eq!(unchecked[0].path, candidates[0].path);
    }

    #[test]
    fn semantic_json_lines_keep_their_limit_and_request_identity() {
        let prefix = br#"{"id":1,"query":"first","limit":9}"#;
        let limit = REQUEST_LINE_LIMIT as usize;
        let mut input = prefix.to_vec();
        input.resize(limit - 1, b' ');
        input.push(b'\n');
        input.extend_from_slice(b"invalid json\n{\"id\":2,\"query\":\"second\"}\n");
        let mut seen = Vec::new();
        let mut output = Vec::new();
        serve_gemma(Cursor::new(input), &mut output, |query, limit| {
            seen.push((query.to_owned(), limit));
            Ok(Vec::new())
        })
        .unwrap();
        assert_eq!(seen, [("first".into(), 9), ("second".into(), 20)]);
        let replies: Vec<serde_json::Value> = output
            .split_inclusive(|&byte| byte == b'\n')
            .map(|line| serde_json::from_slice(line).unwrap())
            .collect();
        assert_eq!(replies.len(), 3);
        assert_eq!(replies[0], json!({"id":1,"hits":[]}));
        assert!(replies[1]["error"].is_string());
        assert_eq!(replies[2], json!({"id":2,"hits":[]}));
    }

    #[test]
    fn semantic_framing_stops_before_reading_or_processing_an_excess_line() {
        let limit = REQUEST_LINE_LIMIT as usize;
        for (input, bytes_read) in [(vec![b' '; limit * 2], limit + 1), (b"{}".to_vec(), 2)] {
            let mut input = Cursor::new(input);
            let mut output = Vec::new();
            let result = serve_gemma(&mut input, &mut output, |_, _| {
                panic!("invalid frame reached the worker")
            });
            assert!(
                result
                    .unwrap_err()
                    .to_string()
                    .contains("invalid semantic request frame")
            );
            assert_eq!(input.position(), bytes_read as u64);
            assert!(output.is_empty());
        }
    }
}
