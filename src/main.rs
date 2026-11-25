use anyhow::{Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use lumen::{Mode, Model, Scope};
use serde::Deserialize;
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
#[derive(Subcommand)]
enum Action {
    /// Index the readable startup volume by default, or explicit roots. Metadata only unless --documents.
    Index {
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
    },
    /// Query a saved index; never implicitly rebuild it.
    Query {
        text: String,
        #[arg(long, value_enum, default_value = "name")]
        mode: SearchMode,
        #[arg(long, default_value_t = 20)]
        limit: usize,
        #[arg(long)]
        helper: Option<PathBuf>,
        #[arg(long, default_value = "en")]
        language: String,
    },
    /// Build one bounded batch of document embeddings from an explicitly chosen local helper.
    Embed {
        #[arg(long)]
        helper: PathBuf,
        #[arg(long, default_value = "en")]
        language: String,
        #[arg(long, default_value_t = 32)]
        max: usize,
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

fn main() -> Result<()> {
    let cli = Cli::parse();
    let db = cli.db.unwrap_or_else(lumen::standard_database);
    match cli.command {
        Action::Index {
            root,
            allow,
            deny,
            documents,
            pdf_helper,
        } => {
            println!(
                "{}",
                serde_json::to_string_pretty(&lumen::scan(
                    &db,
                    &Scope {
                        roots: root,
                        allow,
                        deny,
                        documents,
                        pdf_helper,
                    }
                )?)?
            );
        }
        Action::Query {
            text,
            mode,
            limit,
            helper,
            language,
        } => {
            let model = helper.map(|executable| Model {
                executable,
                language,
            });
            let conn =
                lumen::open_read(&db).with_context(|| "no usable index; run lumen index first")?;
            println!(
                "{}",
                serde_json::to_string_pretty(&lumen::search(
                    &conn,
                    &text,
                    mode.into(),
                    limit,
                    model.as_ref()
                )?)?
            );
        }
        Action::Embed {
            helper,
            language,
            max,
        } => {
            println!(
                "{}",
                json!({"new_embeddings":lumen::embed(&db,&Model{executable:helper,language},max)?})
            );
        }
        Action::Status => {
            println!(
                "{}",
                serde_json::to_string_pretty(&lumen::status(&lumen::open_read(&db)?)?)?
            );
        }
        Action::Serve => {
            let conn = lumen::open_read(&db).context("no usable index; run lumen index first")?;
            let mut out = io::BufWriter::new(io::stdout().lock());
            for line in io::stdin().lock().lines() {
                let data = line?;
                let result = match serde_json::from_str::<Request>(&data) {
                    Ok(q) => {
                        match lumen::search(&conn, &q.query, q.mode, q.limit.unwrap_or(20), None) {
                            Ok(h) => json!({"id":q.id,"hits":h}),
                            Err(e) => json!({"id":q.id,"error":e.to_string()}),
                        }
                    }
                    Err(e) => json!({"error":e.to_string()}),
                };
                writeln!(out, "{result}")?;
                out.flush()?;
            }
        }
    }
    Ok(())
}
