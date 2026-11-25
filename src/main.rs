use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand, ValueEnum};
use lumen::{BgeModel, Mode, Model, ModelBackend, Scope};
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
    #[arg(long, requires = "documents")]
    pdf_helper: Option<PathBuf>,
}

impl From<ScopeArgs> for Scope {
    fn from(args: ScopeArgs) -> Self {
        Self {
            roots: args.root,
            allow: args.allow,
            deny: args.deny,
            documents: args.documents,
            pdf_helper: args.pdf_helper,
        }
    }
}

#[derive(Args)]
struct SemanticArgs {
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
}

impl SemanticArgs {
    fn configure(self) -> Result<Option<ConfiguredModel>> {
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
        }
    }
}

#[derive(Subcommand)]
enum Action {
    /// Index the readable startup volume by default, or explicit roots. Metadata only unless --documents.
    Index(ScopeArgs),
    /// Reconcile and maintain an index. Emits JSON ready and updated events. Diagnostics go to stderr.
    Watch(ScopeArgs),
    /// Query a saved index; never implicitly rebuild it.
    Query {
        text: String,
        #[arg(long, value_enum, default_value = "name")]
        mode: SearchMode,
        #[arg(long, default_value_t = 20)]
        limit: usize,
        #[command(flatten)]
        semantic: SemanticArgs,
    },
    /// Embed the next batch of document chunks using an explicitly chosen local helper.
    Embed {
        #[command(flatten)]
        semantic: SemanticArgs,
        /// Maximum number of encodable chunks to process in this batch.
        #[arg(long, default_value_t = 32)]
        max: usize,
    },
    /// Detect installed BGE candidate retrieval resources without modifying the index.
    ModelStatus {
        #[arg(long, default_value = "zh")]
        language: String,
        #[arg(long, value_name = "DIR")]
        bge_home: Option<PathBuf>,
        /// Launch the worker and check pinned hashes, runtime and model format.
        #[arg(long)]
        verify: bool,
    },
    /// Report scan coverage and embedding counts.
    Status,
    /// Persistent newline-delimited JSON query transport on stdio for the desktop launcher.
    Serve,
}
#[derive(Deserialize)]
struct Request {
    id: u64,
    query: String,
    #[serde(default)]
    mode: Mode,
    limit: Option<usize>,
}

#[derive(Serialize)]
struct SearchReply {
    id: u64,
    hits: Vec<lumen::Hit>,
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
        Action::Watch(args) => {
            let progress = scan_progress(args.progress)?;
            lumen::watch_with_progress(&db, &args.into(), progress.as_ref(), |event| {
                let mut out = io::stdout().lock();
                serde_json::to_writer(&mut out, &event)?;
                writeln!(out)?;
                out.flush()?;
                Ok(())
            })?;
        }
        Action::Query {
            text,
            mode,
            limit,
            semantic,
        } => {
            let model = semantic.configure()?;
            let conn =
                lumen::open_read(&db).with_context(|| "no usable index; run lumen index first")?;
            println!(
                "{}",
                serde_json::to_string_pretty(&lumen::search_with_backend(
                    &conn,
                    &text,
                    mode.into(),
                    limit,
                    model.as_ref().map(ConfiguredModel::backend),
                )?)?
            );
        }
        Action::Embed { semantic, max } => {
            let model = semantic.configure()?.context("embed requires --helper")?;
            println!(
                "{}",
                serde_json::to_string(&lumen::embed_batch(&db, model.backend(), max)?)?
            );
        }
        Action::ModelStatus {
            language,
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
        Action::Status => {
            println!(
                "{}",
                serde_json::to_string_pretty(&lumen::status(&lumen::open_read(&db)?)?)?
            );
        }
        Action::Serve => {
            let mut search = lumen::SearchSession::open(&db)
                .context("no usable index; run lumen index first")?;
            let mut out = io::BufWriter::new(io::stdout().lock());
            for line in io::stdin().lock().lines() {
                let data = line?;
                match serde_json::from_str::<Request>(&data) {
                    Ok(q) => match search.search(&q.query, q.mode, q.limit.unwrap_or(20)) {
                        Ok(hits) => {
                            serde_json::to_writer(&mut out, &SearchReply { id: q.id, hits })?
                        }
                        Err(e) => serde_json::to_writer(
                            &mut out,
                            &json!({"id":q.id,"error":e.to_string()}),
                        )?,
                    },
                    Err(e) => serde_json::to_writer(&mut out, &json!({"error":e.to_string()}))?,
                }
                writeln!(out)?;
                out.flush()?;
            }
        }
    }
    Ok(())
}
