//! A bounded host for a subset of local Raycast no-view extensions.

mod package_files;
mod program;
mod snapshot;

use anyhow::{Context, Result, bail, ensure};
use program::{Program, is_identifier};
use serde::{Deserialize, Serialize, de::IgnoredAny};
use snapshot::Snapshot;
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};

const MAX_MANIFEST_BYTES: u64 = 64 * 1024;
const MAX_SOURCE_BYTES: u64 = 16 * 1024;
const MAX_COMMANDS: usize = 64;
const MAX_ARGUMENT_BYTES: usize = 1024;

#[derive(Debug, Serialize)]
pub struct ExtensionInfo {
    pub name: String,
    pub title: String,
    pub description: String,
    pub version: Option<String>,
    pub snapshot: Option<String>,
    pub commands: Vec<CommandInfo>,
}

#[derive(Debug, Serialize)]
pub struct CommandInfo {
    pub name: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub description: String,
    pub mode: String,
    pub keywords: Vec<String>,
    pub arguments: Vec<ArgumentInfo>,
    pub unsupported_reason: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ArgumentInfo {
    pub name: String,
    pub placeholder: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub required: bool,
    #[serde(default, rename = "data", skip_serializing)]
    data: Option<IgnoredAny>,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(untagged)]
pub enum RunOutput {
    Hud { hud: String },
    Clipboard { clipboard: ClipboardIntent },
}

/// Plain text for a caller to preview and copy only on user confirmation.
#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct ClipboardIntent {
    pub text: String,
}

#[derive(Debug)]
pub struct Extension {
    info: ExtensionInfo,
    programs: BTreeMap<String, Program>,
}

impl Extension {
    /// Inspect one explicitly selected package, compiling only supported commands.
    /// Command source is parsed as data and never evaluated as JavaScript.
    pub fn open(directory: &Path) -> Result<Self> {
        #[cfg(target_os = "macos")]
        let _io_policy = package_files::NoMaterialization::enter()?;
        let package = package_files::open_package(directory)?;
        let manifest = package_files::read_file(&package, "package.json", MAX_MANIFEST_BYTES)?;
        let raw: Manifest = serde_json::from_str(&manifest).context("parse package.json")?;
        validate_manifest(&raw)?;
        let mut snapshot = Snapshot::new(&package, &manifest)?;

        let sources = package_files::open_sources(&package);
        let mut info = ExtensionInfo {
            name: raw.name,
            title: raw.title,
            description: raw.description,
            version: raw.version,
            snapshot: None,
            commands: Vec::with_capacity(raw.commands.len()),
        };
        let mut programs = BTreeMap::new();
        for command in raw.commands {
            let support = command.unsupported_features();
            let mut metadata = command.info();
            match support.and_then(|()| compile(&metadata, &sources, &mut snapshot)) {
                Ok(program) => {
                    programs.insert(metadata.name.clone(), program);
                }
                Err(error) => metadata.unsupported_reason = Some(format!("{error:#}")),
            }
            info.commands.push(metadata);
        }
        info.snapshot = snapshot.finish()?;
        Ok(Self { info, programs })
    }

    pub fn info(&self) -> &ExtensionInfo {
        &self.info
    }

    /// Run the validated in-memory program. All results are data without side effects.
    pub fn run(&self, name: &str, arguments: &BTreeMap<String, String>) -> Result<RunOutput> {
        let command = self
            .info
            .commands
            .iter()
            .find(|command| command.name == name)
            .with_context(|| format!("unknown command {name:?}"))?;
        if let Some(reason) = &command.unsupported_reason {
            bail!("command {name:?} is unsupported: {reason}");
        }
        for argument in &command.arguments {
            let value = arguments
                .get(&argument.name)
                .with_context(|| format!("missing required argument {:?}", argument.name))?;
            ensure!(
                !value.is_empty() && value.len() <= MAX_ARGUMENT_BYTES,
                "argument {:?} must contain 1 to {MAX_ARGUMENT_BYTES} UTF-8 bytes",
                argument.name
            );
        }
        ensure!(
            arguments.len() == command.arguments.len(),
            "unexpected command arguments"
        );
        let program = self
            .programs
            .get(name)
            .context("missing validated command")?;
        program.run(arguments)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    name: String,
    title: String,
    description: String,
    platforms: Vec<String>,
    commands: Vec<ManifestCommand>,
    dependencies: BTreeMap<String, String>,
    version: Option<String>,
    // Display, distribution and package-manager metadata. No paths are read,
    // and npm scripts and development dependencies are inert in this host.
    #[serde(rename = "author")]
    _author: Option<IgnoredAny>,
    #[serde(rename = "icon")]
    _icon: Option<IgnoredAny>,
    #[serde(rename = "categories")]
    _categories: Option<IgnoredAny>,
    #[serde(rename = "license")]
    _license: Option<IgnoredAny>,
    #[serde(rename = "keywords")]
    _keywords: Option<IgnoredAny>,
    #[serde(rename = "scripts")]
    _scripts: Option<IgnoredAny>,
    #[serde(rename = "devDependencies")]
    _dev_dependencies: Option<IgnoredAny>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct ManifestCommand {
    name: String,
    title: String,
    subtitle: Option<String>,
    description: String,
    mode: String,
    #[serde(default)]
    keywords: Vec<String>,
    #[serde(default)]
    arguments: Vec<ArgumentInfo>,
    interval: Option<IgnoredAny>,
    preferences: Option<IgnoredAny>,
    #[serde(default)]
    disabled_by_default: bool,
    #[serde(rename = "icon")]
    _icon: Option<IgnoredAny>,
}

impl ManifestCommand {
    fn unsupported_features(&self) -> Result<()> {
        ensure!(
            self.mode == "no-view",
            "only no-view commands are supported"
        );
        ensure!(self.interval.is_none(), "background refresh is unsupported");
        ensure!(
            self.preferences.is_none(),
            "command preferences are unsupported"
        );
        ensure!(!self.disabled_by_default, "command is disabled by default");
        Ok(())
    }

    fn info(self) -> CommandInfo {
        CommandInfo {
            name: self.name,
            title: self.title,
            subtitle: self.subtitle,
            description: self.description,
            mode: self.mode,
            keywords: self.keywords,
            arguments: self.arguments,
            unsupported_reason: None,
        }
    }
}

fn validate_manifest(manifest: &Manifest) -> Result<()> {
    ensure!(is_slug(&manifest.name), "invalid package name");
    ensure!(valid_label(&manifest.title), "invalid package title");
    ensure!(
        valid_label(&manifest.description),
        "invalid package description"
    );
    ensure!(
        manifest.version.as_deref().is_none_or(valid_label),
        "invalid package version"
    );
    ensure!(
        manifest
            .platforms
            .iter()
            .any(|platform| platform == "macOS")
            && manifest
                .platforms
                .iter()
                .all(|platform| matches!(platform.as_str(), "macOS" | "Windows")),
        "extension must declare macOS support"
    );
    ensure!(
        manifest.dependencies.len() == 1
            && manifest
                .dependencies
                .get("@raycast/api")
                .is_some_and(|version| !version.trim().is_empty()),
        "the only runtime dependency must be @raycast/api"
    );
    ensure!(
        (1..=MAX_COMMANDS).contains(&manifest.commands.len()),
        "package must declare 1 to {MAX_COMMANDS} commands"
    );

    let mut names = BTreeSet::new();
    for command in &manifest.commands {
        ensure!(is_slug(&command.name), "invalid command name");
        ensure!(names.insert(&command.name), "duplicate command name");
        ensure!(
            valid_label(&command.title)
                && valid_label(&command.description)
                && command.subtitle.as_deref().is_none_or(valid_label)
                && command.keywords.iter().all(|word| valid_label(word)),
            "invalid display metadata for command {:?}",
            command.name
        );
    }
    Ok(())
}

fn compile(
    metadata: &CommandInfo,
    sources: &Result<std::fs::File>,
    snapshot: &mut Snapshot,
) -> Result<Program> {
    ensure!(
        metadata.arguments.len() <= 3,
        "at most three arguments are supported"
    );
    let mut names = BTreeSet::new();
    for argument in &metadata.arguments {
        ensure!(
            argument.kind == "text" && argument.required && argument.data.is_none(),
            "only required text arguments are supported"
        );
        ensure!(
            argument.name.len() <= 64
                && is_identifier(&argument.name)
                && valid_label(&argument.placeholder),
            "invalid argument metadata"
        );
        ensure!(names.insert(&argument.name), "duplicate argument name");
    }
    let sources = sources
        .as_ref()
        .map_err(|error| anyhow::anyhow!("{error:#}"))?;
    let name = format!("{}.js", metadata.name);
    let source = package_files::read_file(sources, &name, MAX_SOURCE_BYTES)?;
    snapshot.source(&name, &source);
    Program::compile(&source, &metadata.arguments).with_context(|| format!("validate src/{name}"))
}

fn is_slug(value: &str) -> bool {
    fn alphanumeric(byte: &u8) -> bool {
        byte.is_ascii_lowercase() || byte.is_ascii_digit()
    }

    let bytes = value.as_bytes();
    bytes.len() <= 64
        && bytes.first().is_some_and(alphanumeric)
        && bytes.last().is_some_and(alphanumeric)
        && bytes.iter().all(|byte| alphanumeric(byte) || *byte == b'-')
}

fn valid_label(value: &str) -> bool {
    !value.trim().is_empty() && value.len() <= 1024 && !value.chars().any(char::is_control)
}
