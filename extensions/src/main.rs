use anyhow::{Result, bail};
use clap::{Parser, Subcommand};
use lumen_extensions::Extension;
use std::{collections::BTreeMap, path::PathBuf, process::ExitCode};

#[derive(Parser)]
#[command(version, about = "Lumen's restricted Raycast no-view extension host")]
struct Cli {
    /// Local directory containing package.json and src/.
    #[arg(long)]
    package: PathBuf,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Inspect a package and report which commands can run.
    List,
    /// Run one command and print its HUD or clipboard preview as JSON.
    Run {
        name: String,
        /// Run only if the local package still matches this list result.
        #[arg(long)]
        expect_snapshot: Option<String>,
        /// Pass a declared argument as name=value. Repeat for each argument.
        #[arg(long = "arg", value_name = "NAME=VALUE")]
        arguments: Vec<String>,
    },
}

fn main() -> Result<ExitCode> {
    let cli = Cli::parse();
    let expected = match &cli.command {
        Command::List => None,
        Command::Run {
            expect_snapshot, ..
        } => expect_snapshot.as_deref(),
    };
    let extension = match Extension::open(&cli.package) {
        Ok(extension) => extension,
        Err(error) if expected.is_some() => return Ok(stale_snapshot(&format!("{error:#}"))),
        Err(error) => return Err(error),
    };
    if let Some(expected) = expected
        && extension.info().snapshot.as_deref() != Some(expected)
    {
        return Ok(stale_snapshot(
            "the current package does not match the listed snapshot",
        ));
    }
    match cli.command {
        Command::List => println!("{}", serde_json::to_string(extension.info())?),
        Command::Run {
            name, arguments, ..
        } => {
            let mut values = BTreeMap::new();
            for argument in arguments {
                let Some((name, value)) = argument.split_once('=') else {
                    bail!("expected --arg name=value");
                };
                if values.insert(name.to_owned(), value.to_owned()).is_some() {
                    bail!("duplicate argument {name:?}");
                }
            }
            let result = extension.run(&name, &values)?;
            println!("{}", serde_json::to_string(&result)?);
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn stale_snapshot(detail: &str) -> ExitCode {
    eprintln!("extension snapshot could not be verified; refresh the command list: {detail}");
    ExitCode::from(3)
}
