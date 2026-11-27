use anyhow::{Context, Result, bail, ensure};
use std::{
    fs,
    io::Write,
    path::PathBuf,
    process::{Command, Stdio},
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
pub(crate) struct Unencodable;

impl std::fmt::Display for Unencodable {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("the local model could not encode this input")
    }
}

impl std::error::Error for Unencodable {}

#[derive(Clone, Copy)]
pub enum ModelBackend<'a> {
    Helper(&'a Model),
    Gemma(&'a crate::GemmaModel),
    LocalOpenAi(&'a crate::LocalOpenAiConfig),
}

#[derive(Clone, Copy)]
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
    Gemma(crate::gemma::GemmaWorker),
    LocalOpenAi(crate::local_openai::LocalOpenAiWorker),
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
            Self::LocalOpenAi(config) => {
                let worker = crate::local_openai::LocalOpenAiWorker::new(config)?;
                let (signature, _) = worker.probe()?;
                Ok(Encoder {
                    signature,
                    kind: EncoderKind::LocalOpenAi(worker),
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
            EncoderKind::Gemma(worker) => worker.encode(role, text)?,
            EncoderKind::LocalOpenAi(worker) => match role {
                Role::Query => worker.encode_query(text)?,
                Role::Passage => worker.encode_passage(text)?,
            },
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
            EncoderKind::Gemma(_) | EncoderKind::LocalOpenAi(_) => "semantic_candidate",
        }
    }

    pub fn includes(&self, score: f32) -> bool {
        match self.kind {
            EncoderKind::Helper(_) => score > 0.25,
            EncoderKind::Gemma(_) | EncoderKind::LocalOpenAi(_) => score > 0.0,
        }
    }
}
