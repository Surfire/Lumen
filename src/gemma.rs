//! Owns a pinned llama.cpp child over a private Unix socket.
use crate::model::{Role, Unencodable};
use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, DirBuilder, File, OpenOptions},
    io::{self, Read, Write},
    os::unix::{
        fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt},
        net::UnixStream,
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

pub const DIMENSIONS: usize = 768;
pub const ID: &str = "gemma2/text/q8_0/b11457/retrieval-v1/768/l2/2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135";
const MODEL_FILE: &str = "embeddinggemma-2-Q8_0.gguf";
const PROJECTOR_FILE: &str = "mmproj-embeddinggemma-2-Q8_0.gguf";
const VERIFICATION_CACHE: &str = ".verified-assets-v1.json";
const MAX_CACHE_BYTES: u64 = 64 * 1024;
// Sixteen 768-dimensional JSON vectors stay well below this reply limit.
const MAX_FRAME: usize = 2 * 1024 * 1024;
const START_TIMEOUT: Duration = Duration::from_secs(15);
const ENCODE_TIMEOUT: Duration = Duration::from_secs(8);
const MAX_PASSAGE_BYTES: usize = 8192;
/// Passages sent per `POST /v1/embeddings` request.
pub(crate) const PASSAGE_BATCH: usize = 16;
const PASSAGE_BATCH_BYTES: usize = 12_000;
const PARALLEL_SLOTS: usize = 4;
const SLOT_CONTEXT: usize = 2048;
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
        self.assets(false, None)
    }

    fn assets(&self, verify: bool, projector: Option<&Path>) -> Result<()> {
        ensure!(
            cfg!(all(target_os = "macos", target_arch = "aarch64")),
            "Gemma requires Apple Silicon macOS"
        );
        let manifest: Manifest =
            serde_json::from_str(include_str!("../scripts/gemma-assets.json"))?;
        self.check_assets(&manifest, verify, projector)?;
        Ok(())
    }

    // Return the number of assets actually hashed, not including cache hits.
    fn check_assets(
        &self,
        manifest: &Manifest,
        verify: bool,
        projector: Option<&Path>,
    ) -> Result<usize> {
        let runtime = self.home.join("runtime");
        let private_home = check_directory(&self.home)?.uid() == unsafe { libc::geteuid() };
        check_directory(&runtime)?;
        let cache_path = self.home.join(VERIFICATION_CACHE);
        let mut cache = if verify && private_home {
            read_verifications(&cache_path).unwrap_or_default()
        } else {
            Verifications::new()
        };
        let mut hashed = usize::from(asset(
            &self.home.join(MODEL_FILE),
            &manifest.model,
            verify,
            &mut cache,
        )?);
        for (name, expected) in &manifest.runtime {
            hashed += usize::from(asset(&runtime.join(name), expected, verify, &mut cache)?);
        }
        if let Some(projector) = projector {
            hashed += usize::from(asset(
                projector,
                &manifest.image_projector,
                verify,
                &mut cache,
            )?);
        }
        if hashed != 0 && private_home {
            // A read-only home or a failed cache write must not block verified assets.
            let _ = write_verifications(&self.home, &cache_path, &cache);
        }
        Ok(hashed)
    }

    /// Whether the optional image projector sits beside the text model.
    pub(crate) fn has_image_projector(&self) -> bool {
        fs::symlink_metadata(self.home.join(PROJECTOR_FILE)).is_ok_and(|meta| meta.is_file())
    }

    pub(crate) fn start(&self) -> Result<GemmaWorker> {
        self.start_profile(None)
    }

    pub(crate) fn start_images(&self, projector: &Path) -> Result<GemmaWorker> {
        self.start_profile(Some(crate::absolute(projector)?))
    }

    fn start_profile(&self, projector: Option<PathBuf>) -> Result<GemmaWorker> {
        self.assets(true, projector.as_deref())?;
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
        let cpus = thread::available_parallelism().map_or(4, |n| n.get());
        let child = command
            .arg("--host")
            .arg(&worker.socket)
            .args([
                "--offline",
                "--embedding",
                "--embd-normalize",
                "2",
                "--no-ui",
                "--batch-size",
                "4096",
                "--ubatch-size",
                "2048",
                "--gpu-layers",
                "99",
            ])
            // llama-server splits the context across slots; keep 2048 tokens per slot.
            .arg("--parallel")
            .arg(PARALLEL_SLOTS.to_string())
            .arg("--ctx-size")
            .arg((PARALLEL_SLOTS * SLOT_CONTEXT).to_string())
            .arg("--threads")
            .arg((cpus / 2).clamp(2, 6).to_string())
            .arg("--threads-batch")
            .arg(cpus.clamp(4, 8).to_string())
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

fn check_directory(path: &Path) -> Result<fs::Metadata> {
    let meta = fs::metadata(path).context("Gemma resource directory is missing")?;
    ensure!(
        meta.is_dir() && meta.mode() & 0o002 == 0,
        "Gemma resource directory must be a directory that is not world-writable"
    );
    Ok(meta)
}

#[derive(Deserialize, Serialize, PartialEq, Eq)]
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

#[derive(Deserialize, Serialize)]
struct Verification {
    metadata: AssetMetadata,
    sha256: String,
}

type Verifications = BTreeMap<String, Verification>;

fn read_verifications(path: &Path) -> Result<Verifications> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let meta = file.metadata()?;
    ensure!(
        meta.is_file() && meta.mode() & 0o777 == 0o600 && meta.uid() == unsafe { libc::geteuid() },
        "unsafe Gemma verification cache"
    );
    let mut bytes = Vec::new();
    file.take(MAX_CACHE_BYTES + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() as u64 <= MAX_CACHE_BYTES,
        "oversized Gemma verification cache"
    );
    Ok(serde_json::from_slice(&bytes)?)
}

fn write_verifications(home: &Path, path: &Path, cache: &Verifications) -> Result<()> {
    let mut nonce = [0_u8; 8];
    File::open("/dev/urandom")?.read_exact(&mut nonce)?;
    let temporary = home.join(format!(
        "{VERIFICATION_CACHE}.{:016x}.tmp",
        u64::from_ne_bytes(nonce)
    ));
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    // Publish complete JSON in one rename without following an existing symlink.
    let result = (|| -> Result<()> {
        serde_json::to_writer(file, cache)?;
        fs::rename(&temporary, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

// Return whether this call actually hashed the asset.
fn asset(path: &Path, expected: &Asset, verify: bool, cache: &mut Verifications) -> Result<bool> {
    let mut file = OpenOptions::new()
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
    if canonical
        .to_str()
        .and_then(|path| cache.get(path))
        .is_some_and(|cached| cached.metadata == metadata && cached.sha256 == expected.sha256)
    {
        return Ok(false);
    }
    let digest = sha256_file(&mut file)?;
    ensure!(
        digest == expected.sha256,
        "Gemma asset failed SHA-256 verification: {}",
        path.file_name().unwrap_or_default().to_string_lossy()
    );
    ensure!(
        metadata == AssetMetadata::from(&file.metadata()?),
        "Gemma asset changed during SHA-256 verification"
    );
    if let Some(path) = canonical.to_str() {
        cache.insert(
            path.into(),
            Verification {
                metadata,
                sha256: expected.sha256.clone(),
            },
        );
    }
    Ok(true)
}

fn sha256_file(reader: &mut impl Read) -> Result<String> {
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => hasher.update(&buffer[..count]),
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error).context("verify Gemma SHA-256"),
        }
    }
    Ok(hasher.finalize_hex())
}

struct Sha256 {
    state: [u32; 8],
    buffer: [u8; 64],
    buffered: usize,
    len_bytes: u64,
}

impl Sha256 {
    const INIT: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];
    #[rustfmt::skip]
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];

    fn new() -> Self {
        Self {
            state: Self::INIT,
            buffer: [0; 64],
            buffered: 0,
            len_bytes: 0,
        }
    }

    fn update(&mut self, mut input: &[u8]) {
        self.len_bytes = self.len_bytes.wrapping_add(input.len() as u64);
        if self.buffered > 0 {
            let take = (64 - self.buffered).min(input.len());
            self.buffer[self.buffered..self.buffered + take].copy_from_slice(&input[..take]);
            self.buffered += take;
            input = &input[take..];
            if self.buffered == 64 {
                Self::compress(&mut self.state, &self.buffer);
                self.buffered = 0;
            }
        }
        while input.len() >= 64 {
            let (block, rest) = input.split_at(64);
            Self::compress(&mut self.state, block.try_into().expect("64-byte block"));
            input = rest;
        }
        if !input.is_empty() {
            self.buffer[..input.len()].copy_from_slice(input);
            self.buffered = input.len();
        }
    }

    fn finalize_hex(mut self) -> String {
        let bit_len = (u128::from(self.len_bytes) << 3) as u64;
        self.buffer[self.buffered] = 0x80;
        self.buffered += 1;
        if self.buffered > 56 {
            self.buffer[self.buffered..64].fill(0);
            Self::compress(&mut self.state, &self.buffer);
            self.buffered = 0;
        }
        self.buffer[self.buffered..56].fill(0);
        self.buffer[56..64].copy_from_slice(&bit_len.to_be_bytes());
        Self::compress(&mut self.state, &self.buffer);
        self.state
            .into_iter()
            .flat_map(u32::to_be_bytes)
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }

    fn compress(state: &mut [u32; 8], block: &[u8; 64]) {
        let mut w = [0_u32; 64];
        for (i, word) in w[..16].iter_mut().enumerate() {
            let off = i * 4;
            *word =
                u32::from_be_bytes([block[off], block[off + 1], block[off + 2], block[off + 3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = *state;
        for (&word, &k) in w.iter().zip(&Self::K) {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = h
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(k)
                .wrapping_add(word);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);
            h = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }
        for (slot, delta) in state.iter_mut().zip([a, b, c, d, e, f, g, h]) {
            *slot = slot.wrapping_add(delta);
        }
    }
}

pub(crate) struct GemmaWorker {
    owner: Option<Child>,
    private: PathBuf,
    socket: PathBuf,
    key: String,
}

impl GemmaWorker {
    pub(crate) fn encode(&mut self, role: Role, text: &str) -> Result<Vec<f32>> {
        if !encodable(text) {
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

    /// Encodes passages in batched requests. `None` marks an unencodable
    /// passage; `Err` is a hard runtime failure.
    pub(crate) fn encode_passages(&mut self, texts: &[&str]) -> Result<Vec<Option<Vec<f32>>>> {
        let mut vectors = vec![None; texts.len()];
        let valid: Vec<usize> = (0..texts.len()).filter(|&i| encodable(texts[i])).collect();
        let mut start = 0;
        while start < valid.len() {
            let mut end = start;
            let mut bytes = 0;
            while end < valid.len()
                && end - start < PASSAGE_BATCH
                && (end == start || bytes + texts[valid[end]].len() <= PASSAGE_BATCH_BYTES)
            {
                bytes += texts[valid[end]].len();
                end += 1;
            }
            let group: Vec<&str> = valid[start..end].iter().map(|&i| texts[i]).collect();
            for (&i, vector) in valid[start..end].iter().zip(self.encode_bisect(&group)?) {
                vectors[i] = vector;
            }
            start = end;
        }
        Ok(vectors)
    }

    // Split rejected requests so one unencodable passage never fails its neighbors.
    fn encode_bisect(&self, texts: &[&str]) -> Result<Vec<Option<Vec<f32>>>> {
        let inputs: Vec<String> = texts
            .iter()
            .map(|text| format!("title: none | text: {text}"))
            .collect();
        let timeout = ENCODE_TIMEOUT + Duration::from_secs(2) * texts.len() as u32;
        match self.embed(serde_json::json!(inputs), texts.len(), timeout) {
            Err(error) if error.is::<Unencodable>() && texts.len() == 1 => Ok(vec![None]),
            Err(error) if error.is::<Unencodable>() => {
                let mid = texts.len() / 2;
                let mut vectors = self.encode_bisect(&texts[..mid])?;
                vectors.extend(self.encode_bisect(&texts[mid..])?);
                Ok(vectors)
            }
            result => Ok(result?.into_iter().map(Some).collect()),
        }
    }

    fn encode_input(&self, input: serde_json::Value, timeout: Duration) -> Result<Vec<f32>> {
        Ok(self
            .embed(serde_json::json!([input]), 1, timeout)?
            .swap_remove(0))
    }

    fn embed(
        &self,
        inputs: serde_json::Value,
        count: usize,
        timeout: Duration,
    ) -> Result<Vec<Vec<f32>>> {
        let payload = serde_json::to_vec(&serde_json::json!({"input":inputs}))?;
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
            data: Vec<Embedding>,
        }
        #[derive(Deserialize)]
        struct Embedding {
            embedding: Vec<f32>,
            index: usize,
        }
        let Response { data } =
            serde_json::from_slice(&body).context("invalid Gemma embedding reply")?;
        ensure!(
            data.len() == count,
            "Gemma returned a mismatched embedding count"
        );
        let mut vectors = vec![None; count];
        for row in data {
            let length: f32 = row.embedding.iter().map(|x| x * x).sum();
            ensure!(
                row.embedding.len() == DIMENSIONS && (length - 1.0).abs() < 0.01,
                "Gemma returned an invalid 768-dimensional normalized vector"
            );
            let slot = vectors
                .get_mut(row.index)
                .filter(|slot| slot.is_none())
                .context("Gemma returned an invalid embedding index")?;
            *slot = Some(row.embedding);
        }
        // Every slot is filled: `count` rows each claimed a distinct index below `count`.
        Ok(vectors.into_iter().flatten().collect())
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
            // macOS rejects socket options with EINVAL once the server has hung
            // up; buffered reply bytes and EOF remain readable without blocking.
            match stream.set_read_timeout(Some(remaining(deadline)?)) {
                Err(error) if error.kind() == io::ErrorKind::InvalidInput => {}
                result => result?,
            }
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

fn encodable(text: &str) -> bool {
    !text.trim().is_empty() && text.len() <= MAX_PASSAGE_BYTES
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
    fn verification_cache_survives_fresh_models_and_invalidates_on_metadata_or_digest_change() {
        let home = std::env::temp_dir().join(format!("lumen-gemma-digest-{}", std::process::id()));
        DirBuilder::new().mode(0o700).create(&home).unwrap();
        DirBuilder::new()
            .mode(0o700)
            .create(home.join("runtime"))
            .unwrap();
        let path = home.join(MODEL_FILE);
        let projector = home.join("projector.gguf");
        fs::write(&path, b"abc").unwrap();
        fs::write(&projector, b"abc").unwrap();
        let sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        let expected = || Asset {
            size: 3,
            sha256: sha256.into(),
        };
        let mut manifest = Manifest {
            model: expected(),
            image_projector: expected(),
            runtime: BTreeMap::new(),
        };
        let check = |manifest: &Manifest, verify, projector: Option<&Path>| {
            GemmaModel::installed(Some(&home))
                .unwrap()
                .check_assets(manifest, verify, projector)
        };
        let cache = home.join(VERIFICATION_CACHE);
        assert_eq!(check(&manifest, false, None).unwrap(), 0);
        assert!(!cache.exists());
        assert_eq!(check(&manifest, true, None).unwrap(), 1);
        assert_eq!(fs::metadata(&cache).unwrap().mode() & 0o777, 0o600);
        assert_eq!(check(&manifest, true, Some(&projector)).unwrap(), 1);
        assert_eq!(check(&manifest, true, Some(&projector)).unwrap(), 0);
        assert_eq!(check(&manifest, true, None).unwrap(), 0);

        // An unsafe cache is a miss. Publishing a fresh cache must not follow
        // a symlink or modify its target, even if it contains valid entries.
        let target = home.join("moved-cache");
        fs::rename(&cache, &target).unwrap();
        let contents = fs::read(&target).unwrap();
        std::os::unix::fs::symlink(&target, &cache).unwrap();
        assert_eq!(check(&manifest, true, Some(&projector)).unwrap(), 2);
        assert_eq!(fs::read(&target).unwrap(), contents);
        assert!(fs::symlink_metadata(&cache).unwrap().is_file());

        manifest.model.sha256 = "0".repeat(64);
        assert!(
            check(&manifest, true, None)
                .unwrap_err()
                .to_string()
                .contains("failed SHA-256")
        );
        manifest.model = expected();
        let file = fs::OpenOptions::new().write(true).open(&path).unwrap();
        let mtime: SystemTime = UNIX_EPOCH + Duration::new(1_700_000_000, 123456789);
        file.set_times(FileTimes::new().set_modified(mtime))
            .unwrap();
        assert_eq!(check(&manifest, true, None).unwrap(), 1);
        assert_eq!(check(&manifest, true, None).unwrap(), 0);
        fs::set_permissions(&path, fs::Permissions::from_mode(0o500)).unwrap();
        assert_eq!(check(&manifest, true, None).unwrap(), 1);
        (&file).write_all(b"bad").unwrap();
        file.set_times(FileTimes::new().set_modified(mtime))
            .unwrap();
        assert!(
            check(&manifest, true, None)
                .unwrap_err()
                .to_string()
                .contains("failed SHA-256")
        );
        fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn pure_rust_sha256_matches_nist_vectors_and_streaming_chunks() {
        let digest = |bytes: &[u8]| {
            let mut hasher = Sha256::new();
            hasher.update(bytes);
            hasher.finalize_hex()
        };
        assert_eq!(
            digest(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            digest(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            digest(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
        // Multi-block (>64 bytes) NIST vector fed in uneven chunks and via File.
        let multi = b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu";
        let expected_multi = "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1";
        let mut streamed = Sha256::new();
        for chunk in multi.chunks(7) {
            streamed.update(chunk);
        }
        assert_eq!(streamed.finalize_hex(), expected_multi);

        let dir = std::env::temp_dir().join(format!("lumen-sha256-stream-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let big_path = dir.join("multi-buffer.bin");
        let big_bytes = vec![b'a'; 150_000];
        fs::write(&big_path, &big_bytes).unwrap();
        let mut file = File::open(&big_path).unwrap();
        assert_eq!(sha256_file(&mut file).unwrap(), digest(&big_bytes));
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn symlinked_gemma_directory_allows_external_ssd_while_blocking_world_writable_or_symlink_files()
     {
        let root = std::env::temp_dir().join(format!("lumen-gemma-symlink-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let ssd = root.join("external-ssd/Gemma2");
        let runtime = ssd.join("runtime");
        fs::create_dir_all(&runtime).unwrap();
        fs::set_permissions(&ssd, fs::Permissions::from_mode(0o775)).unwrap();
        fs::set_permissions(&runtime, fs::Permissions::from_mode(0o775)).unwrap();
        fs::write(ssd.join(MODEL_FILE), b"abc").unwrap();
        let linked_home = root.join("Library/Gemma2");
        fs::create_dir_all(linked_home.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&ssd, &linked_home).unwrap();

        let expected = Asset {
            size: 3,
            sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad".into(),
        };
        let manifest = Manifest {
            model: expected,
            image_projector: Asset {
                size: 3,
                sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad".into(),
            },
            runtime: BTreeMap::new(),
        };
        let model = GemmaModel::installed(Some(&linked_home)).unwrap();
        assert_eq!(model.check_assets(&manifest, true, None).unwrap(), 1);
        assert_eq!(model.check_assets(&manifest, true, None).unwrap(), 0);

        // World-writable directory is still rejected.
        fs::set_permissions(&ssd, fs::Permissions::from_mode(0o777)).unwrap();
        assert!(
            model
                .check_assets(&manifest, false, None)
                .unwrap_err()
                .to_string()
                .contains("world-writable")
        );
        fs::set_permissions(&ssd, fs::Permissions::from_mode(0o755)).unwrap();

        // Individual model files must still be non-symlink regular files (O_NOFOLLOW).
        let target_model = root.join("elsewhere.gguf");
        fs::rename(ssd.join(MODEL_FILE), &target_model).unwrap();
        std::os::unix::fs::symlink(&target_model, ssd.join(MODEL_FILE)).unwrap();
        assert!(model.check_assets(&manifest, true, None).is_err());

        fs::remove_dir_all(&root).unwrap();
    }

    type Reply = fn(&[String]) -> (u16, String);

    // Serves llama.cpp-shaped `/v1/embeddings` replies on a private Unix socket
    // and records the number of inputs in every request.
    fn stub_worker(name: &str, reply: Reply) -> (GemmaWorker, std::sync::mpsc::Receiver<usize>) {
        use std::os::unix::net::UnixListener;
        let private = PathBuf::from(format!(
            "/private/tmp/lumen-gemma-stub-{}-{name}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&private);
        DirBuilder::new().mode(0o700).create(&private).unwrap();
        let socket = private.join("worker.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let (sizes, received) = std::sync::mpsc::channel();
        thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { return };
                let mut request = Vec::new();
                let mut buffer = [0; 8192];
                let body = loop {
                    let count = stream.read(&mut buffer).unwrap();
                    request.extend_from_slice(&buffer[..count]);
                    let Some(end) = request.windows(4).position(|b| b == b"\r\n\r\n") else {
                        continue;
                    };
                    let headers = std::str::from_utf8(&request[..end]).unwrap();
                    let length: usize = headers
                        .lines()
                        .find_map(|line| line.strip_prefix("Content-Length: "))
                        .unwrap()
                        .trim()
                        .parse()
                        .unwrap();
                    if request.len() >= end + 4 + length {
                        break request[end + 4..end + 4 + length].to_vec();
                    }
                };
                let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
                let inputs: Vec<String> = serde_json::from_value(json["input"].clone()).unwrap();
                let _ = sizes.send(inputs.len());
                let (status, reply) = reply(&inputs);
                let _ = write!(
                    stream,
                    "HTTP/1.1 {status} X\r\nContent-Length: {}\r\n\r\n{reply}",
                    reply.len()
                );
            }
        });
        let worker = GemmaWorker {
            owner: None,
            private,
            socket,
            key: "test".into(),
        };
        (worker, received)
    }

    // Input `t<k> ...` embeds as the unit vector on axis k.
    fn one_hot(input: &str) -> Vec<f32> {
        let text = input.strip_prefix("title: none | text: t").unwrap();
        let axis: usize = text.split(' ').next().unwrap().parse().unwrap();
        let mut vector = vec![0.0; DIMENSIONS];
        vector[axis] = 1.0;
        vector
    }

    fn rows(inputs: &[String], index: impl Fn(usize) -> usize) -> String {
        let data: Vec<_> = inputs
            .iter()
            .enumerate()
            .rev()
            .map(|(i, input)| serde_json::json!({"index": index(i), "embedding": one_hot(input)}))
            .collect();
        serde_json::json!({ "data": data }).to_string()
    }

    #[test]
    fn batched_passages_map_reply_indices_and_bisect_around_unencodable_inputs() {
        let (mut worker, sizes) = stub_worker("batch", |inputs| {
            if inputs.iter().any(|input| input.ends_with("BAD")) {
                return (
                    400,
                    r#"{"error":{"message":"input exceeds the context size"}}"#.into(),
                );
            }
            (200, rows(inputs, |i| i))
        });
        let long = "x".repeat(MAX_PASSAGE_BYTES + 1);
        let texts: Vec<String> = (0..20)
            .map(|k| match k {
                3 => "  ".into(),
                5 => long.clone(),
                7 => "t7 BAD".into(),
                _ => format!("t{k}"),
            })
            .collect();
        let refs: Vec<&str> = texts.iter().map(String::as_str).collect();
        let vectors = worker.encode_passages(&refs).unwrap();
        assert_eq!(vectors.len(), 20);
        for (k, vector) in vectors.iter().enumerate() {
            if [3, 5, 7].contains(&k) {
                assert!(vector.is_none(), "item {k} must be skipped");
            } else {
                let vector = vector.as_ref().unwrap();
                assert_eq!(vector[k], 1.0, "item {k} must keep its own vector");
            }
        }
        // 18 locally valid passages: a 16-item request bisects down to the one
        // rejected passage, then the 2 remaining passages share one request.
        let sent: Vec<usize> = sizes.try_iter().collect();
        assert_eq!(sent, [16, 8, 4, 4, 2, 1, 1, 2, 8, 2]);

        // Requests stay below the UTF-8 byte budget.
        let padded: Vec<String> = (0..4)
            .map(|k| format!("t{k} {}", "y".repeat(5000)))
            .collect();
        let refs: Vec<&str> = padded.iter().map(String::as_str).collect();
        let vectors = worker.encode_passages(&refs).unwrap();
        assert!((0..4).all(|k| vectors[k].as_ref().unwrap()[k] == 1.0));
        assert_eq!(sizes.try_iter().collect::<Vec<_>>(), [2, 2]);

        // Single-item callers keep the prior contract.
        assert_eq!(worker.encode(Role::Passage, "t9").unwrap()[9], 1.0);
        assert!(
            worker
                .encode(Role::Passage, "t1 BAD")
                .unwrap_err()
                .is::<Unencodable>()
        );
    }

    #[test]
    fn batched_passages_reject_duplicate_indices_and_server_failures() {
        let (mut worker, _) = stub_worker("index", |inputs| (200, rows(inputs, |_| 0)));
        let error = worker.encode_passages(&["t1", "t2"]).unwrap_err();
        assert!(!error.is::<Unencodable>());
        assert!(error.to_string().contains("index"), "{error}");

        let (mut worker, _) = stub_worker("failure", |_| (500, "{}".into()));
        let error = worker.encode_passages(&["t1", "t2"]).unwrap_err();
        assert!(!error.is::<Unencodable>());
    }
}
