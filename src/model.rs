use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{self, BufRead, BufReader, Write},
    os::{fd::AsRawFd, unix::fs::PermissionsExt},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
    time::{Duration, Instant},
};

#[derive(Clone, Debug)]
pub struct Model {
    pub executable: PathBuf,
    pub language: String,
}

impl Model {
    fn signature(&self) -> Result<String> {
        let p = fs::canonicalize(&self.executable)?;
        let m = fs::metadata(&p)?;
        Ok(format!(
            "{}:{}:{:?}:{}",
            p.display(),
            m.len(),
            m.modified()?,
            self.language
        ))
    }
    fn encode(&self, text: &str) -> Result<Vec<f32>> {
        let mut p = Command::new(&self.executable)
            .arg(&self.language)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .context("launch local semantic model")?;
        p.stdin
            .take()
            .context("local model stdin")?
            .write_all(text.as_bytes())?;
        let output = p.wait_with_output()?;
        if output.status.code() == Some(3) {
            return Err(Unencodable.into());
        }
        if !output.status.success() {
            bail!(
                "local semantic model unavailable: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        Ok(serde_json::from_slice(&output.stdout)?)
    }
}

#[derive(Debug)]
pub(super) struct Unencodable;

impl std::fmt::Display for Unencodable {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("the local model could not encode this input")
    }
}

impl std::error::Error for Unencodable {}

#[derive(Clone, Debug)]
pub struct BgeModel {
    pub python: PathBuf,
    pub helper: PathBuf,
    pub directory: PathBuf,
    pub language: String,
}

impl BgeModel {
    pub fn installed(home: Option<&Path>, language: &str) -> Result<Self> {
        let language = bge_language(language)?;
        let home = match home {
            Some(home) => home.to_path_buf(),
            None => PathBuf::from(
                std::env::var_os("HOME").context("cannot locate user model resources")?,
            )
            .join("Library/Application Support/Lumen/Semantic"),
        };
        let helper = std::env::current_exe()?.with_file_name("local-bge.py");
        Ok(Self {
            python: home.join("runtime/bin/python3"),
            helper,
            directory: home.join("models").join(language),
            language: language.into(),
        })
    }

    pub fn check_installed_files(&self) -> Result<()> {
        let python = fs::metadata(&self.python).context("isolated BGE runtime is missing")?;
        ensure!(
            python.is_file() && python.permissions().mode() & 0o111 != 0,
            "isolated BGE runtime is not executable"
        );
        ensure!(
            self.helper.is_file(),
            "BGE worker is missing beside the lumen executable"
        );
        for file in ["config.json", "tokenizer.json", "model.safetensors"] {
            ensure!(
                self.directory.join(file).is_file(),
                "BGE {} profile is missing {file}",
                self.language
            );
        }
        Ok(())
    }

    pub fn verify(&self) -> Result<()> {
        self.check_installed_files()?;
        let _worker = ModelBackend::Bge(self).connect()?;
        Ok(())
    }
}

fn bge_language(language: &str) -> Result<&'static str> {
    match language {
        "zh" | "zh-Hans" => Ok("zh"),
        "en" => Ok("en"),
        _ => bail!("the optional BGE backend supports zh and en profiles"),
    }
}

#[derive(Clone, Copy)]
pub enum ModelBackend<'a> {
    Helper(&'a Model),
    Bge(&'a BgeModel),
    Gemma(&'a crate::GemmaModel),
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Role {
    Query,
    Passage,
}

pub(super) struct Encoder<'a> {
    signature: String,
    kind: EncoderKind<'a>,
}

enum EncoderKind<'a> {
    Helper(&'a Model),
    Bge(BgeWorker),
    Gemma(crate::gemma::GemmaWorker),
}

impl<'a> ModelBackend<'a> {
    pub(super) fn connect(self) -> Result<Encoder<'a>> {
        match self {
            Self::Helper(model) => Ok(Encoder {
                signature: model.signature()?,
                kind: EncoderKind::Helper(model),
            }),
            Self::Gemma(model) => Ok(Encoder {
                signature: crate::gemma::ID.into(),
                kind: EncoderKind::Gemma(model.start()?),
            }),
            Self::Bge(model) => {
                let (worker, signature) = BgeWorker::start(model)?;
                Ok(Encoder {
                    signature,
                    kind: EncoderKind::Bge(worker),
                })
            }
        }
    }
}

impl Encoder<'_> {
    pub fn signature(&self) -> &str {
        &self.signature
    }

    pub fn encode(&mut self, role: Role, text: &str) -> Result<Vec<f32>> {
        let mut vector = match &mut self.kind {
            EncoderKind::Helper(model) => model.encode(text)?,
            EncoderKind::Bge(worker) => worker.encode(role, text)?,
            EncoderKind::Gemma(worker) => worker.encode(role, text)?,
        };
        ensure!(
            (8..=4096).contains(&vector.len()) && vector.iter().all(|x| x.is_finite()),
            "invalid local model vector"
        );
        let length = vector.iter().map(|x| x * x).sum::<f32>().sqrt();
        ensure!(length.is_finite(), "invalid local model norm");
        if length <= f32::EPSILON {
            return Err(Unencodable.into());
        }
        for value in &mut vector {
            *value /= length;
        }
        Ok(vector)
    }

    pub fn match_reason(&self) -> &'static str {
        match self.kind {
            EncoderKind::Helper(_) => "semantic",
            EncoderKind::Bge(_) | EncoderKind::Gemma(_) => "semantic_candidate",
        }
    }

    pub fn includes(&self, score: f32) -> bool {
        match self.kind {
            EncoderKind::Helper(_) => score > 0.25,
            EncoderKind::Bge(_) | EncoderKind::Gemma(_) => score > 0.0,
        }
    }
}

const WORKER_PROTOCOL: u32 = 1;
const MAX_WORKER_REPLY: usize = 65_536;
const WORKER_REPLY_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Deserialize)]
struct WorkerReady {
    protocol: u32,
    language: String,
    fingerprint: String,
    dimensions: usize,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum WorkerVector {
    Encoded { vector: Vec<f32> },
    Skipped { unencodable: bool },
}

#[derive(Serialize)]
struct WorkerRequest<'a> {
    role: Role,
    text: &'a str,
}

struct BgeWorker {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    dimensions: usize,
}

impl BgeWorker {
    fn start(model: &BgeModel) -> Result<(Self, String)> {
        let language = bge_language(&model.language)?;
        let mut child = Command::new(&model.python)
            .arg("-I")
            .arg(&model.helper)
            .arg("--model-dir")
            .arg(&model.directory)
            .arg("--language")
            .arg(language)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .context("launch offline BGE worker")?;
        let input = child.stdin.take().context("BGE worker input")?;
        let output = BufReader::new(child.stdout.take().context("BGE worker output")?);
        let mut worker = Self {
            child,
            input,
            output,
            dimensions: 0,
        };
        let ready: WorkerReady = worker
            .receive()
            .context("start BGE profile with verified local model files")?;
        let dimensions = if language == "zh" { 512 } else { 384 };
        ensure!(
            ready.protocol == WORKER_PROTOCOL
                && ready.language == language
                && ready.dimensions == dimensions
                && ready.fingerprint.len() == 64
                && ready.fingerprint.bytes().all(|b| b.is_ascii_hexdigit()),
            "unsupported BGE worker capability or profile"
        );
        worker.dimensions = dimensions;
        // Keep helper vectors separated even if their dimensions happen to match.
        Ok((
            worker,
            format!("bge/{WORKER_PROTOCOL}/{language}/{}", ready.fingerprint),
        ))
    }

    fn encode(&mut self, role: Role, text: &str) -> Result<Vec<f32>> {
        serde_json::to_writer(&mut self.input, &WorkerRequest { role, text })?;
        self.input.write_all(b"\n")?;
        self.input.flush()?;
        match self.receive()? {
            WorkerVector::Encoded { vector } => {
                ensure!(
                    vector.len() == self.dimensions,
                    "BGE worker changed vector dimensions"
                );
                Ok(vector)
            }
            WorkerVector::Skipped { unencodable: true } => Err(Unencodable.into()),
            WorkerVector::Skipped { unencodable: false } => {
                bail!("invalid BGE worker input status")
            }
        }
    }

    fn receive<T: serde::de::DeserializeOwned>(&mut self) -> Result<T> {
        let mut frame = Vec::new();
        let deadline = Instant::now() + WORKER_REPLY_TIMEOUT;
        while !frame.ends_with(b"\n") {
            if self.output.buffer().is_empty() {
                wait_for_reply(self.output.get_ref(), deadline)?;
            }
            let data = self.output.fill_buf()?;
            ensure!(!data.is_empty(), "BGE worker closed its output pipe");
            let length = data
                .iter()
                .position(|b| *b == b'\n')
                .map_or(data.len(), |i| i + 1);
            ensure!(
                frame.len() + length <= MAX_WORKER_REPLY,
                "BGE worker exceeded its reply limit"
            );
            frame.extend_from_slice(&data[..length]);
            self.output.consume(length);
        }
        Ok(serde_json::from_slice(&frame)?)
    }
}

fn wait_for_reply(output: &ChildStdout, deadline: Instant) -> Result<()> {
    let mut fd = libc::pollfd {
        fd: output.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    loop {
        let remain = deadline.saturating_duration_since(Instant::now());
        ensure!(!remain.is_zero(), "BGE worker reply timed out");
        let timeout_ms = remain.as_millis().max(1) as i32;
        let result = unsafe { libc::poll(&mut fd, 1, timeout_ms) };
        if result > 0 {
            return Ok(());
        }
        if result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::Interrupted {
                return Err(error).context("wait for BGE worker output");
            }
        }
    }
}

impl Drop for BgeWorker {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
