//! Owns a pinned llama.cpp child over a private Unix socket.
use crate::model::{Role, Unencodable};
use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;
use std::{
    collections::{BTreeMap, HashMap},
    fs::{self, DirBuilder, File, OpenOptions},
    io::{self, Read, Write},
    os::unix::{
        fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
        net::UnixStream,
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{LazyLock, Mutex},
    thread,
    time::{Duration, Instant},
};

pub const DIMENSIONS: usize = 768;
pub const ID: &str = "gemma2/text/q8_0/b11457/retrieval-v1/768/l2/2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135";
const MODEL_FILE: &str = "embeddinggemma-2-Q8_0.gguf";
const MAX_FRAME: usize = 128 * 1024;
const START_TIMEOUT: Duration = Duration::from_secs(15);
const ENCODE_TIMEOUT: Duration = Duration::from_secs(8);
pub(crate) const IMAGE_MAX_BYTES: u64 = 2 * 1024 * 1024;
const IMAGE_TIMEOUT: Duration = Duration::from_secs(12);

#[derive(Deserialize)]
struct Asset {
    size: u64,
    sha256: String,
}

#[derive(Deserialize)]
struct Manifest {
    model: Asset,
    image_projector: Asset,
    runtime: BTreeMap<String, Asset>,
}

#[derive(Debug)]
pub struct GemmaModel {
    home: PathBuf,
}

impl GemmaModel {
    pub fn installed(home: Option<&Path>) -> Result<Self> {
        let home = match home {
            Some(path) => crate::absolute(path)?,
            None => {
                PathBuf::from(std::env::var_os("HOME").context("cannot locate Gemma resources")?)
                    .join("Library/Application Support/Lumen/Gemma2")
            }
        };
        Ok(Self { home })
    }

    pub fn inspect(&self, verify: bool) -> Result<()> {
        if verify {
            let mut worker = self.start()?;
            return worker.probe();
        }
        self.assets(false)
    }

    fn assets(&self, verify: bool) -> Result<()> {
        ensure!(
            cfg!(all(target_os = "macos", target_arch = "aarch64")),
            "Gemma requires Apple Silicon macOS"
        );
        let manifest: Manifest =
            serde_json::from_str(include_str!("../scripts/gemma-assets.json"))?;
        let runtime = self.home.join("runtime");
        for directory in [&self.home, &runtime] {
            let mode =
                fs::symlink_metadata(directory).context("Gemma resource directory is missing")?;
            ensure!(
                mode.is_dir() && mode.permissions().mode() & 0o022 == 0,
                "Gemma resource directory must be a non-symlink writable only by its owner"
            );
        }
        asset(&self.home.join(MODEL_FILE), &manifest.model, verify)?;
        for (name, expected) in &manifest.runtime {
            asset(&runtime.join(name), expected, verify)?;
        }
        Ok(())
    }

    pub(crate) fn start(&self) -> Result<GemmaWorker> {
        self.start_profile(None)
    }

    pub(crate) fn start_images(&self, projector: &Path) -> Result<GemmaWorker> {
        self.start_profile(Some(crate::absolute(projector)?))
    }

    fn start_profile(&self, projector: Option<PathBuf>) -> Result<GemmaWorker> {
        self.assets(true)?;
        if let Some(path) = &projector {
            let manifest: Manifest =
                serde_json::from_str(include_str!("../scripts/gemma-assets.json"))?;
            asset(path, &manifest.image_projector, true)?;
        }
        let mut random = [0_u8; 32];
        File::open("/dev/urandom")?.read_exact(&mut random)?;
        let address: String = random[..16]
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let key: String = random[16..]
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let private = PathBuf::from(format!("/private/tmp/lumen-gemma-{address}"));
        DirBuilder::new().mode(0o700).create(&private)?;
        let socket = private.join("worker.sock");
        let mut worker = GemmaWorker {
            owner: None,
            private,
            socket,
            key,
        };
        // The shell monitors the write end owned solely by Lumen. It reaps the
        // runtime after EOF, including when the launcher cancels Lumen by signal.
        let supervise = r#"
folder=$1
shift
trap 'exit 0' HUP INT TERM
"$@" </dev/null &
server=$!
trap 'kill -KILL "$server" 2>/dev/null; wait "$server" 2>/dev/null; /bin/rm -f "$folder/worker.sock"; /bin/rmdir "$folder" 2>/dev/null' EXIT
IFS= read -r owner || :
"#;
        let mut command = Command::new("/bin/sh");
        command
            .arg("-c")
            .arg(supervise)
            .arg("lumen-gemma-owner")
            .arg(&worker.private)
            .arg(self.home.join("runtime/llama-server"))
            .arg("--model")
            .arg(self.home.join(MODEL_FILE));
        if let Some(projector) = &projector {
            command.arg("--mmproj").arg(projector);
        }
        let child = command
            .arg("--host")
            .arg(&worker.socket)
            .args([
                "--offline",
                "--embedding",
                "--embd-normalize",
                "2",
                "--no-ui",
                "--parallel",
                "1",
                "--ctx-size",
                "2048",
                "--batch-size",
                "2048",
                "--ubatch-size",
                "2048",
                "--gpu-layers",
                "99",
                "--threads",
                "2",
                "--threads-batch",
                "2",
            ])
            // Give the supervisor and runtime a group entirely owned by this worker.
            .process_group(0)
            .current_dir(&worker.private)
            .env_clear()
            .env("LLAMA_API_KEY", &worker.key)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .context("launch verified Gemma runtime")?;
        worker.owner = Some(child);
        let deadline = Instant::now() + START_TIMEOUT;
        while Instant::now() < deadline {
            let health_deadline = deadline.min(Instant::now() + Duration::from_millis(200));
            if let Ok((200, _)) = worker.request("GET /health", &[], health_deadline) {
                return Ok(worker);
            }
            thread::sleep(Duration::from_millis(20));
        }
        bail!("verified Gemma runtime did not become healthy before the startup deadline")
    }
}

#[derive(PartialEq, Eq)]
struct AssetMetadata {
    dev: u64,
    ino: u64,
    size: u64,
    mtime: (i64, i64),
    ctime: (i64, i64),
    mode: u32,
}

impl From<&fs::Metadata> for AssetMetadata {
    fn from(meta: &fs::Metadata) -> Self {
        Self {
            dev: meta.dev(),
            ino: meta.ino(),
            size: meta.len(),
            mtime: (meta.mtime(), meta.mtime_nsec()),
            ctime: (meta.ctime(), meta.ctime_nsec()),
            mode: meta.mode(),
        }
    }
}

struct Verification {
    metadata: AssetMetadata,
    sha256: String,
}

static VERIFIED_ASSETS: LazyLock<Mutex<HashMap<PathBuf, Verification>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

// Return whether this call actually hashed the asset.
fn asset(path: &Path, expected: &Asset, verify: bool) -> Result<bool> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .with_context(|| {
            format!(
                "missing or unsafe Gemma asset {}",
                path.file_name().unwrap_or_default().to_string_lossy()
            )
        })?;
    let meta = file.metadata()?;
    ensure!(
        meta.is_file() && meta.len() == expected.size && meta.permissions().mode() & 0o022 == 0,
        "invalid Gemma asset type, size or permissions: {}",
        path.file_name().unwrap_or_default().to_string_lossy()
    );
    if !verify {
        return Ok(false);
    }
    let canonical = fs::canonicalize(path)?;
    let metadata = AssetMetadata::from(&meta);
    if VERIFIED_ASSETS
        .lock()
        .unwrap()
        .get(&canonical)
        .is_some_and(|cached| cached.metadata == metadata && cached.sha256 == expected.sha256)
    {
        return Ok(false);
    }
    let output = Command::new("/usr/bin/openssl")
        .args(["dgst", "-sha256", "-r"])
        .env_clear()
        .stdin(Stdio::from(file.try_clone()?))
        .output()
        .context("verify Gemma SHA-256")?;
    ensure!(
        output.status.success()
            && std::str::from_utf8(&output.stdout)?
                .split_whitespace()
                .next()
                == Some(expected.sha256.as_str()),
        "Gemma asset failed SHA-256 verification: {}",
        path.file_name().unwrap_or_default().to_string_lossy()
    );
    ensure!(
        metadata == AssetMetadata::from(&file.metadata()?),
        "Gemma asset changed during SHA-256 verification"
    );
    VERIFIED_ASSETS.lock().unwrap().insert(
        canonical,
        Verification {
            metadata,
            sha256: expected.sha256.clone(),
        },
    );
    Ok(true)
}

pub(crate) struct GemmaWorker {
    owner: Option<Child>,
    private: PathBuf,
    socket: PathBuf,
    key: String,
}

impl GemmaWorker {
    pub(crate) fn encode(&mut self, role: Role, text: &str) -> Result<Vec<f32>> {
        if text.trim().is_empty() || text.len() > 8192 {
            return Err(Unencodable.into());
        }
        let input = match role {
            Role::Query => format!("task: search result | query: {text}"),
            Role::Passage => format!("title: none | text: {text}"),
        };
        self.encode_input(serde_json::json!(input), ENCODE_TIMEOUT)
    }

    pub(crate) fn encode_image(&mut self, bytes: &[u8]) -> Result<Vec<f32>> {
        ensure!(
            bytes.len() as u64 <= IMAGE_MAX_BYTES,
            "image exceeds the input size limit"
        );
        let url = format!("data:image/png;base64,{}", image_base64(bytes));
        self.encode_input(
            serde_json::json!({"content":[{"type":"image_url","image_url":{"url":url}}]}),
            IMAGE_TIMEOUT,
        )
    }

    fn encode_input(&self, input: serde_json::Value, timeout: Duration) -> Result<Vec<f32>> {
        let payload = serde_json::to_vec(&serde_json::json!({"input":[input]}))?;
        let (status, body) =
            self.request("POST /v1/embeddings", &payload, Instant::now() + timeout)?;
        if status == 400
            && (body.windows(9).any(|s| s == b"truncated")
                || body.windows(7).any(|s| s == b"context"))
        {
            return Err(Unencodable.into());
        }
        ensure!(
            status == 200,
            "Gemma inference failed (local HTTP {status})"
        );
        #[derive(Deserialize)]
        struct Response {
            data: [Embedding; 1],
        }
        #[derive(Deserialize)]
        struct Embedding {
            embedding: Vec<f32>,
            index: u32,
        }
        let Response { data: [row] } =
            serde_json::from_slice(&body).context("invalid Gemma embedding reply")?;
        let length: f32 = row.embedding.iter().map(|x| x * x).sum();
        ensure!(
            row.index == 0 && row.embedding.len() == DIMENSIONS && (length - 1.0).abs() < 0.01,
            "Gemma returned an invalid 768-dimensional normalized vector"
        );
        Ok(row.embedding)
    }

    pub(crate) fn probe(&mut self) -> Result<()> {
        let docs = [
            self.encode(
                Role::Passage,
                "Orient the solar panel toward the midday sun.",
            )?,
            self.encode(Role::Passage, "给闹钟换上新的电池以后重新调准时间。")?,
        ];
        for (index, query) in [
            "怎样摆放太阳能板才能让它朝着正午阳光？",
            "How do I get the clock to run after its battery died?",
        ]
        .into_iter()
        .enumerate()
        {
            let vector = self.encode(Role::Query, query)?;
            let score = |document: &[f32]| {
                document
                    .iter()
                    .zip(&vector)
                    .map(|(a, b)| a * b)
                    .sum::<f32>()
            };
            ensure!(
                score(&docs[index]) - score(&docs[1 - index]) > 0.05,
                "Gemma failed the local bilingual retrieval check"
            );
        }
        Ok(())
    }

    fn request(&self, route: &str, payload: &[u8], deadline: Instant) -> Result<(u16, Vec<u8>)> {
        let mut stream = UnixStream::connect(&self.socket)?;
        stream.set_write_timeout(Some(remaining(deadline)?))?;
        write!(
            stream,
            "{route} HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {}\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
            self.key,
            payload.len()
        )?;
        stream.set_write_timeout(Some(remaining(deadline)?))?;
        stream.write_all(payload)?;
        let mut response = Vec::new();
        let mut buffer = [0; 8192];
        loop {
            stream.set_read_timeout(Some(remaining(deadline)?))?;
            let count = stream.read(&mut buffer)?;
            if count == 0 {
                break;
            }
            ensure!(
                response.len() + count <= MAX_FRAME,
                "Gemma reply exceeded its frame limit"
            );
            response.extend_from_slice(&buffer[..count]);
        }
        let end = response
            .windows(4)
            .position(|bytes| bytes == b"\r\n\r\n")
            .context("invalid Gemma response headers")?;
        let headers = std::str::from_utf8(&response[..end])?;
        let mut lines = headers.split("\r\n");
        let mut status_line = lines.next().unwrap_or_default().split_whitespace();
        ensure!(
            status_line.next() == Some("HTTP/1.1"),
            "invalid Gemma HTTP version"
        );
        let status = status_line
            .next()
            .context("missing Gemma response status")?
            .parse()?;
        let length = lines
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("Content-Length")
                    .then_some(value.trim())
            })
            .context("missing Gemma response length")?
            .parse::<usize>()?;
        let body = response.split_off(end + 4);
        ensure!(body.len() == length, "truncated Gemma response body");
        Ok((status, body))
    }
}

fn image_base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut encoded = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let a = chunk[0] as usize;
        let b = chunk.get(1).copied().unwrap_or(0) as usize;
        let c = chunk.get(2).copied().unwrap_or(0) as usize;
        encoded.push(ALPHABET[a >> 2] as char);
        encoded.push(ALPHABET[((a & 3) << 4) | (b >> 4)] as char);
        encoded.push(if chunk.len() >= 2 {
            ALPHABET[((b & 15) << 2) | (c >> 6)] as char
        } else {
            '='
        });
        encoded.push(if chunk.len() == 3 {
            ALPHABET[c & 63] as char
        } else {
            '='
        });
    }
    encoded
}

fn remaining(deadline: Instant) -> io::Result<Duration> {
    let time = deadline.saturating_duration_since(Instant::now());
    if time.is_zero() {
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "Gemma inference deadline elapsed",
        ))
    } else {
        Ok(time)
    }
}

impl Drop for GemmaWorker {
    fn drop(&mut self) {
        if let Some(mut owner) = self.owner.take() {
            drop(owner.stdin.take());
            let deadline = Instant::now() + Duration::from_secs(2);
            while matches!(owner.try_wait(), Ok(None)) {
                if Instant::now() >= deadline {
                    // The group leader is still our unreaped child. Killing the
                    // group also covers a stalled supervisor before its EXIT trap.
                    unsafe { libc::kill(-(owner.id() as libc::pid_t), libc::SIGKILL) };
                    let _ = owner.wait();
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
        }
        let _ = fs::remove_file(&self.socket);
        let _ = fs::remove_dir(&self.private);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::FileTimes;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn asset_digest_cache_reuses_verified_bytes_and_invalidates_on_metadata_or_digest_change() {
        let path = std::env::temp_dir().join(format!("lumen-gemma-digest-{}", std::process::id()));
        fs::write(&path, b"abc").unwrap();
        let expected = Asset {
            size: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad".into(),
        };
        assert!(!asset(&path, &expected, false).unwrap());
        assert!(asset(&path, &expected, true).unwrap());
        assert!(!asset(&path, &expected, true).unwrap());
        let wrong = Asset {
            size: 3,
            sha256: "0".repeat(64),
        };
        assert!(
            asset(&path, &wrong, true)
                .unwrap_err()
                .to_string()
                .contains("failed SHA-256")
        );
        let file = fs::OpenOptions::new().write(true).open(&path).unwrap();
        let mtime: SystemTime = UNIX_EPOCH + Duration::new(1_700_000_000, 123456789);
        file.set_times(FileTimes::new().set_modified(mtime))
            .unwrap();
        assert!(asset(&path, &expected, true).unwrap());
        assert!(!asset(&path, &expected, true).unwrap());
        fs::set_permissions(&path, fs::Permissions::from_mode(0o500)).unwrap();
        assert!(asset(&path, &expected, true).unwrap());
        (&file).write_all(b"bad").unwrap();
        file.set_times(FileTimes::new().set_modified(mtime))
            .unwrap();
        assert!(
            asset(&path, &expected, true)
                .unwrap_err()
                .to_string()
                .contains("failed SHA-256")
        );
        fs::remove_file(&path).unwrap();
    }
}
