//! Strict loopback OpenAI-compatible local text embedding client (pure std).
use crate::model::Unencodable;
use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;
use std::{
    fmt, fs,
    io::{self, Read, Write},
    net::{SocketAddr, TcpStream, ToSocketAddrs},
    os::unix::{fs::FileTypeExt, net::UnixStream},
    path::{Component, Path, PathBuf},
    time::{Duration, Instant},
};

const API_KEY_ENV: &str = "LUMEN_EMBEDDING_API_KEY";
const MAX_RESPONSE_HEADERS: usize = 64 * 1024;
const MAX_RESPONSE_BODY: usize = 32 * 1024 * 1024;
const MAX_CHUNK_LINE: usize = 4096;
const MAX_TRAILER_BYTES: usize = 16 * 1024;
const MAX_PASSAGE_BYTES: usize = 8192;
const PROBE_TIMEOUT: Duration = Duration::from_secs(30);
const BATCH_TIMEOUT: Duration = Duration::from_secs(120);
const CONNECT_ATTEMPT_CAP: Duration = Duration::from_secs(5);
pub(crate) const PASSAGE_BATCH: usize = 16;
const PASSAGE_BATCH_BYTES: usize = 12_000;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocalOpenAiConfig {
    pub url: String,
    pub model: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ValidatedEndpoint {
    Http {
        host: String,
        addrs: Vec<SocketAddr>,
        base_path: String,
    },
    Unix {
        socket_path: PathBuf,
        base_path: String,
    },
}

impl ValidatedEndpoint {
    fn base_path(&self) -> &str {
        match self {
            Self::Http { base_path, .. } | Self::Unix { base_path, .. } => base_path,
        }
    }

    fn route(&self, leaf: &str) -> String {
        let base = self.base_path();
        if base == "/v1" || base.ends_with("/v1") {
            format!("{base}/{leaf}")
        } else {
            format!("{base}/v1/{leaf}")
        }
    }

    fn host_header(&self) -> String {
        match self {
            Self::Http { host, addrs, .. } => {
                let port = addrs.first().map_or(80, SocketAddr::port);
                if port == 80 {
                    host.clone()
                } else {
                    format!("{host}:{port}")
                }
            }
            Self::Unix { .. } => "localhost".into(),
        }
    }
}

pub fn validate_loopback_url(raw: &str) -> Result<ValidatedEndpoint> {
    let raw = raw.trim();
    ensure!(
        !raw.is_empty(),
        "local OpenAI endpoint URL must not be empty"
    );
    ensure!(
        !raw.bytes()
            .any(|b| b.is_ascii_control() || b.is_ascii_whitespace() || b == b'\\'),
        "local OpenAI endpoint URL contains disallowed characters"
    );
    ensure!(
        !raw.contains('?') && !raw.contains('#'),
        "local OpenAI endpoint URL must not contain query or fragment components"
    );

    if let Some(scheme_end) = raw.find("://") {
        let scheme = &raw[..scheme_end];
        let rest = &raw[scheme_end + 3..];
        if scheme.eq_ignore_ascii_case("https") {
            bail!("https:// endpoints are rejected; only loopback http:// or unix:// is allowed");
        }
        if scheme.eq_ignore_ascii_case("unix") {
            return validate_unix_endpoint(rest);
        }
        if scheme.eq_ignore_ascii_case("http") {
            return validate_http_loopback(rest);
        }
        bail!(
            "unsupported endpoint scheme '{scheme}://'; only loopback http:// or unix:// is allowed"
        );
    }
    bail!("local OpenAI endpoint URL must start with http:// or unix://");
}

fn validate_unix_endpoint(rest: &str) -> Result<ValidatedEndpoint> {
    ensure!(
        rest.starts_with('/') && rest.len() > 1,
        "unix:// endpoint must specify an absolute socket path (unix:///abs/path.sock)"
    );
    let socket_path = PathBuf::from(rest);
    ensure!(
        !socket_path
            .components()
            .any(|component| component == Component::ParentDir),
        "unix:// socket path must not contain '..'"
    );
    Ok(ValidatedEndpoint::Unix {
        socket_path,
        base_path: String::new(),
    })
}

fn verify_unix_socket(socket_path: &Path) -> Result<()> {
    let meta = fs::symlink_metadata(socket_path)
        .with_context(|| format!("inspect Unix socket {}", socket_path.display()))?;
    ensure!(
        meta.file_type().is_socket(),
        "unix:// endpoint is not a Unix domain socket: {}",
        socket_path.display()
    );
    Ok(())
}

fn validate_http_loopback(rest: &str) -> Result<ValidatedEndpoint> {
    let (authority, path_raw) = match rest.find('/') {
        Some(idx) => (&rest[..idx], &rest[idx..]),
        None => (rest, ""),
    };
    ensure!(
        !authority.is_empty(),
        "local OpenAI endpoint URL is missing a host"
    );
    ensure!(
        !authority.contains('@'),
        "local OpenAI endpoint URL must not contain userinfo"
    );

    let (display_host, resolve_host, port) = if let Some(after_open) = authority.strip_prefix('[') {
        let close = after_open
            .find(']')
            .context("unterminated IPv6 bracket in endpoint URL")?;
        let inner = &after_open[..close];
        let tail = &after_open[close + 1..];
        ensure!(
            inner == "::1",
            "only loopback IPv6 host [::1] is allowed, got [{inner}]"
        );
        let port = parse_optional_port(tail)?;
        ("[::1]".to_owned(), "::1", port)
    } else {
        ensure!(
            !authority.contains('[') && !authority.contains(']'),
            "malformed brackets in endpoint host"
        );
        let (host_part, tail) = match authority.find(':') {
            Some(colon) => (&authority[..colon], &authority[colon..]),
            None => (authority, ""),
        };
        let port = parse_optional_port(tail)?;
        if host_part == "127.0.0.1" {
            ("127.0.0.1".to_owned(), "127.0.0.1", port)
        } else if host_part.eq_ignore_ascii_case("localhost") {
            ("localhost".to_owned(), "localhost", port)
        } else {
            bail!(
                "non-loopback host '{host_part}' is rejected; only 127.0.0.1, [::1], or localhost is allowed"
            );
        }
    };

    let mut addrs = Vec::new();
    for addr in (resolve_host, port)
        .to_socket_addrs()
        .with_context(|| format!("resolve loopback host '{display_host}'"))?
    {
        ensure!(
            addr.ip().is_loopback(),
            "endpoint host '{display_host}' resolved to non-loopback address {}",
            addr.ip()
        );
        if !addrs.contains(&addr) {
            addrs.push(addr);
        }
    }
    ensure!(
        !addrs.is_empty(),
        "endpoint host '{display_host}' resolved to no loopback addresses"
    );

    let base_path = normalize_base_path(path_raw)?;
    Ok(ValidatedEndpoint::Http {
        host: display_host,
        addrs,
        base_path,
    })
}

fn parse_optional_port(tail: &str) -> Result<u16> {
    if tail.is_empty() {
        return Ok(80);
    }
    let port_str = tail
        .strip_prefix(':')
        .context("unexpected characters after endpoint host")?;
    ensure!(
        !port_str.is_empty() && port_str.bytes().all(|b| b.is_ascii_digit()),
        "invalid port '{port_str}' in endpoint URL"
    );
    let port: u16 = port_str
        .parse()
        .with_context(|| format!("port out of range: '{port_str}'"))?;
    ensure!(port != 0, "endpoint port must not be 0");
    Ok(port)
}

fn normalize_base_path(raw: &str) -> Result<String> {
    if raw.is_empty() || raw == "/" {
        return Ok(String::new());
    }
    ensure!(
        raw.starts_with('/'),
        "endpoint base path must start with '/'"
    );
    ensure!(
        !raw.split('/').any(|segment| segment == ".."),
        "endpoint base path must not contain '..'"
    );
    let trimmed = raw.trim_end_matches('/');
    Ok(trimmed.to_owned())
}

const MAX_SANITIZED_MODEL_LEN: usize = 200;
const MODEL_HASH_HEX_LEN: usize = 12;
const MAX_HASHED_MODEL_PREFIX_LEN: usize = MAX_SANITIZED_MODEL_LEN - 1 - MODEL_HASH_HEX_LEN;

fn is_safe_model_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-' | '/' | ':' | '+')
}

fn sha256_hex_12(input: &[u8]) -> String {
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
        for (&word, &k) in w.iter().zip(&K) {
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

    let mut state = INIT;
    let bit_len = (input.len() as u64).wrapping_mul(8);
    let mut rest = input;
    while rest.len() >= 64 {
        let (block, tail) = rest.split_at(64);
        compress(&mut state, block.try_into().expect("64-byte block"));
        rest = tail;
    }
    let mut block = [0_u8; 64];
    block[..rest.len()].copy_from_slice(rest);
    block[rest.len()] = 0x80;
    if rest.len() + 1 > 56 {
        compress(&mut state, &block);
        block.fill(0);
    }
    block[56..64].copy_from_slice(&bit_len.to_be_bytes());
    compress(&mut state, &block);

    let mut hex = String::with_capacity(MODEL_HASH_HEX_LEN);
    for byte in state
        .into_iter()
        .flat_map(u32::to_be_bytes)
        .take(MODEL_HASH_HEX_LEN / 2)
    {
        use fmt::Write as _;
        let _ = write!(&mut hex, "{byte:02x}");
    }
    hex
}

/// Sanitize a user-configured model identifier for the canonical signature
/// `openai-local:<sanitized>@<dims>`.
///
/// Preserves exact `<raw>` when trimmed `model` contains only safe ASCII chars
/// (`a-zA-Z0-9._-/:+`) and `len <= 200`; appends `~<12-hex-sha256>` of the raw
/// trimmed model whenever characters are sanitized or truncated so distinct raw
/// names never collide on the same partition key.
pub fn sanitize_model_name(model: &str) -> String {
    let trimmed = model.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if trimmed.len() <= MAX_SANITIZED_MODEL_LEN && trimmed.chars().all(is_safe_model_char) {
        return trimmed.to_owned();
    }
    let mut out = String::with_capacity(
        trimmed.len().min(MAX_HASHED_MODEL_PREFIX_LEN) + 1 + MODEL_HASH_HEX_LEN,
    );
    let mut prev_underscore = false;
    for ch in trimmed.chars() {
        if out.len() >= MAX_HASHED_MODEL_PREFIX_LEN {
            break;
        }
        if is_safe_model_char(ch) {
            out.push(ch);
            prev_underscore = false;
        } else if !prev_underscore && !out.is_empty() {
            out.push('_');
            prev_underscore = true;
        }
    }
    while out.ends_with('_') {
        out.pop();
    }
    out.push('~');
    out.push_str(&sha256_hex_12(trimmed.as_bytes()));
    out
}

pub fn canonical_model_id(model: &str, dims: usize) -> String {
    format!("openai-local:{}@{dims}", sanitize_model_name(model))
}

pub(crate) fn canonical_model_prefix(model: &str) -> String {
    format!("openai-local:{}@", sanitize_model_name(model))
}

pub fn list_models_for_url(url: &str) -> Result<Vec<String>> {
    let worker = LocalOpenAiWorker::from_url(url)?;
    worker.list_models()
}

pub struct LocalOpenAiWorker {
    endpoint: ValidatedEndpoint,
    model: String,
    api_key: Option<String>,
}

impl fmt::Debug for LocalOpenAiWorker {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LocalOpenAiWorker")
            .field("endpoint", &self.endpoint)
            .field("model", &self.model)
            .field("has_api_key", &self.api_key.is_some())
            .finish()
    }
}

impl LocalOpenAiWorker {
    pub fn new(config: &LocalOpenAiConfig) -> Result<Self> {
        let endpoint = validate_loopback_url(&config.url)?;
        let api_key = read_api_key_from_env()?;
        Ok(Self {
            endpoint,
            model: config.model.trim().to_owned(),
            api_key,
        })
    }

    pub fn from_url(url: &str) -> Result<Self> {
        let endpoint = validate_loopback_url(url)?;
        let api_key = read_api_key_from_env()?;
        Ok(Self {
            endpoint,
            model: String::new(),
            api_key,
        })
    }

    #[cfg(test)]
    fn with_api_key(mut self, key: Option<String>) -> Self {
        self.api_key = key;
        self
    }

    pub fn endpoint(&self) -> &ValidatedEndpoint {
        &self.endpoint
    }

    pub fn model(&self) -> &str {
        &self.model
    }

    fn require_model(&self) -> Result<&str> {
        ensure!(
            !self.model.is_empty(),
            "local OpenAI embedding model must not be empty"
        );
        ensure!(
            !sanitize_model_name(&self.model).is_empty(),
            "local OpenAI embedding model name contains no valid identifier characters"
        );
        Ok(&self.model)
    }

    /// Lightweight availability probe used by `model-status` without `--verify`.
    pub fn check_reachable(&self) -> Result<()> {
        let _ = self.require_model()?;
        let route = self.endpoint.route("models");
        let (status, body) = self.request("GET", &route, None, Instant::now() + PROBE_TIMEOUT)?;
        if status == 401 || status == 403 {
            bail!(
                "local OpenAI endpoint rejected credentials (HTTP {status}): {}",
                error_preview(&body)
            );
        }
        ensure!(
            status == 200 || status == 404 || status == 405,
            "local OpenAI endpoint returned HTTP {status}: {}",
            error_preview(&body)
        );
        Ok(())
    }

    pub fn list_models(&self) -> Result<Vec<String>> {
        let route = self.endpoint.route("models");
        let (status, body) = self.request("GET", &route, None, Instant::now() + PROBE_TIMEOUT)?;
        ensure!(
            status == 200,
            "local OpenAI /models failed (HTTP {status}): {}",
            error_preview(&body)
        );
        #[derive(Deserialize)]
        struct ModelsReply {
            #[serde(default)]
            data: Vec<ModelEntry>,
        }
        #[derive(Deserialize)]
        struct ModelEntry {
            id: String,
        }
        let reply: ModelsReply =
            serde_json::from_slice(&body).context("invalid local OpenAI /models JSON reply")?;
        let mut models: Vec<String> = reply
            .data
            .into_iter()
            .map(|entry| entry.id.trim().to_owned())
            .filter(|id| !id.is_empty())
            .collect();
        models.sort();
        models.dedup();
        Ok(models)
    }

    pub fn probe(&self) -> Result<(String, usize)> {
        self.probe_with_timeout(PROBE_TIMEOUT)
    }

    pub fn probe_with_timeout(&self, timeout: Duration) -> Result<(String, usize)> {
        let model = self.require_model()?;
        let vectors = self.embed_batch(&["lumen"], timeout)?;
        ensure!(
            vectors.len() == 1,
            "local OpenAI probe returned {} vectors instead of 1",
            vectors.len()
        );
        let dims = vectors[0].len();
        ensure!(
            (8..=4096).contains(&dims),
            "local OpenAI embedding dimensions {dims} outside supported range 8..=4096"
        );
        Ok((canonical_model_id(model, dims), dims))
    }

    pub fn encode_query(&self, text: &str) -> Result<Vec<f32>> {
        let _ = self.require_model()?;
        if !encodable(text) {
            return Err(Unencodable.into());
        }
        let mut vectors = self.embed_batch(&[text], PROBE_TIMEOUT)?;
        ensure!(
            vectors.len() == 1,
            "local OpenAI query returned mismatched vector count"
        );
        Ok(vectors.swap_remove(0))
    }

    pub fn encode_passage(&self, text: &str) -> Result<Vec<f32>> {
        let _ = self.require_model()?;
        if !encodable(text) {
            return Err(Unencodable.into());
        }
        let mut vectors = self.embed_batch(&[text], BATCH_TIMEOUT)?;
        ensure!(
            vectors.len() == 1,
            "local OpenAI passage returned mismatched vector count"
        );
        Ok(vectors.swap_remove(0))
    }

    pub fn encode_passages(&self, texts: &[&str]) -> Result<Vec<Option<Vec<f32>>>> {
        let _ = self.require_model()?;
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

    fn encode_bisect(&self, texts: &[&str]) -> Result<Vec<Option<Vec<f32>>>> {
        match self.embed_batch(texts, BATCH_TIMEOUT) {
            Err(error) if error.is::<Unencodable>() && texts.len() == 1 => Ok(vec![None]),
            Err(error) if error.is::<Unencodable>() => {
                let mid = texts.len() / 2;
                let mut vectors = self.encode_bisect(&texts[..mid])?;
                vectors.extend(self.encode_bisect(&texts[mid..])?);
                Ok(vectors)
            }
            Ok(vectors) => Ok(vectors.into_iter().map(Some).collect()),
            Err(error) => Err(error),
        }
    }

    fn embed_batch(&self, texts: &[&str], timeout: Duration) -> Result<Vec<Vec<f32>>> {
        let model = self.require_model()?;
        let route = self.endpoint.route("embeddings");
        let payload = serde_json::to_vec(&serde_json::json!({
            "model": model,
            "input": texts,
        }))?;
        let (status, body) =
            self.request("POST", &route, Some(&payload), Instant::now() + timeout)?;
        if is_unencodable_http_error(status, &body) {
            return Err(Unencodable.into());
        }
        ensure!(
            status == 200,
            "local OpenAI embeddings failed (HTTP {status}): {}",
            error_preview(&body)
        );
        #[derive(Deserialize)]
        struct EmbeddingsReply {
            data: Vec<EmbeddingItem>,
        }
        #[derive(Deserialize)]
        struct EmbeddingItem {
            embedding: Vec<f32>,
            #[serde(default)]
            index: Option<usize>,
        }
        let EmbeddingsReply { data } =
            serde_json::from_slice(&body).context("invalid local OpenAI embeddings JSON reply")?;
        ensure!(
            data.len() == texts.len(),
            "local OpenAI returned {} embeddings for {} inputs",
            data.len(),
            texts.len()
        );
        let mut ordered: Vec<Option<Vec<f32>>> = vec![None; texts.len()];
        let mut expected_dims: Option<usize> = None;
        for (pos, row) in data.into_iter().enumerate() {
            let idx = row.index.unwrap_or(pos);
            let slot = ordered
                .get_mut(idx)
                .filter(|slot| slot.is_none())
                .context("local OpenAI returned invalid or duplicate embedding index")?;
            let normalized = normalize_vector(row.embedding)?;
            match expected_dims {
                None => expected_dims = Some(normalized.len()),
                Some(dims) => ensure!(
                    normalized.len() == dims,
                    "local OpenAI returned inconsistent vector dimensions ({} vs {dims})",
                    normalized.len()
                ),
            }
            *slot = Some(normalized);
        }
        Ok(ordered.into_iter().flatten().collect())
    }

    fn request(
        &self,
        method: &str,
        route: &str,
        payload: Option<&[u8]>,
        deadline: Instant,
    ) -> Result<(u16, Vec<u8>)> {
        let mut stream = EndpointStream::connect(&self.endpoint, deadline)?;
        let mut request = Vec::with_capacity(256 + payload.map_or(0, <[u8]>::len));
        write!(
            request,
            "{method} {route} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\nAccept: application/json\r\n",
            self.endpoint.host_header()
        )?;
        if let Some(key) = self.api_key.as_deref() {
            write!(request, "Authorization: Bearer {key}\r\n")?;
        }
        if let Some(body) = payload {
            write!(
                request,
                "Content-Type: application/json\r\nContent-Length: {}\r\n",
                body.len()
            )?;
        }
        request.extend_from_slice(b"\r\n");
        if let Some(body) = payload {
            request.extend_from_slice(body);
        }
        stream.write_all_deadline(&request, deadline)?;
        read_http_response(&mut stream, deadline)
    }
}

fn read_api_key_from_env() -> Result<Option<String>> {
    let Some(raw) = std::env::var(API_KEY_ENV).ok() else {
        return Ok(None);
    };
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    ensure!(
        !trimmed.bytes().any(|b| b == b'\r' || b == b'\n' || b == 0),
        "{API_KEY_ENV} must not contain control characters"
    );
    Ok(Some(trimmed.to_owned()))
}

fn normalize_vector(mut vector: Vec<f32>) -> Result<Vec<f32>> {
    ensure!(
        (8..=4096).contains(&vector.len()) && vector.iter().all(|x| x.is_finite()),
        "local OpenAI returned invalid embedding vector"
    );
    let length = vector.iter().map(|x| x * x).sum::<f32>().sqrt();
    ensure!(length.is_finite(), "local OpenAI returned non-finite norm");
    if length <= f32::EPSILON {
        return Err(Unencodable.into());
    }
    for value in &mut vector {
        *value /= length;
    }
    Ok(vector)
}

fn encodable(text: &str) -> bool {
    !text.trim().is_empty() && text.len() <= MAX_PASSAGE_BYTES
}

fn is_unencodable_http_error(status: u16, body: &[u8]) -> bool {
    if status == 413 {
        return true;
    }
    if status != 400 && status != 500 {
        return false;
    }
    let lower = String::from_utf8_lossy(body).to_ascii_lowercase();
    [
        "context",
        "too long",
        "too large",
        "length",
        "truncat",
        "token",
        "sequence",
        "max_position",
        "exceed",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

fn error_preview(body: &[u8]) -> String {
    let text = String::from_utf8_lossy(body);
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return "(empty response body)".into();
    }
    let mut end = trimmed.len().min(240);
    while !trimmed.is_char_boundary(end) {
        end -= 1;
    }
    trimmed[..end].replace(['\r', '\n'], " ")
}

fn remaining(deadline: Instant) -> io::Result<Duration> {
    let left = deadline.saturating_duration_since(Instant::now());
    if left.is_zero() {
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "local OpenAI request deadline elapsed",
        ))
    } else {
        Ok(left)
    }
}

enum EndpointStream {
    Tcp(TcpStream),
    Unix(UnixStream),
}

impl EndpointStream {
    fn connect(endpoint: &ValidatedEndpoint, deadline: Instant) -> Result<Self> {
        match endpoint {
            ValidatedEndpoint::Http { host, addrs, .. } => {
                let mut last_err = None;
                for addr in addrs {
                    ensure!(
                        addr.ip().is_loopback(),
                        "refusing non-loopback connection target {}",
                        addr.ip()
                    );
                    let timeout = remaining(deadline)?.min(CONNECT_ATTEMPT_CAP);
                    match TcpStream::connect_timeout(addr, timeout) {
                        Ok(stream) => return Ok(Self::Tcp(stream)),
                        Err(err) => last_err = Some(err),
                    }
                }
                Err(last_err.map_or_else(
                    || anyhow::anyhow!("no loopback addresses available for {host}"),
                    |err| {
                        anyhow::Error::new(err)
                            .context(format!("connect to loopback endpoint {host}"))
                    },
                ))
            }
            ValidatedEndpoint::Unix { socket_path, .. } => {
                verify_unix_socket(socket_path)?;
                let stream = UnixStream::connect(socket_path)
                    .with_context(|| format!("connect to Unix socket {}", socket_path.display()))?;
                Ok(Self::Unix(stream))
            }
        }
    }

    fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        match self {
            Self::Tcp(stream) => stream.set_read_timeout(timeout),
            Self::Unix(stream) => stream.set_read_timeout(timeout),
        }
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        match self {
            Self::Tcp(stream) => stream.set_write_timeout(timeout),
            Self::Unix(stream) => stream.set_write_timeout(timeout),
        }
    }

    fn read_chunk(&mut self, buf: &mut [u8], deadline: Instant) -> io::Result<usize> {
        loop {
            // macOS rejects socket options with EINVAL once the peer has closed;
            // buffered bytes and EOF remain readable without blocking.
            match self.set_read_timeout(Some(remaining(deadline)?)) {
                Err(err) if err.kind() == io::ErrorKind::InvalidInput => {}
                result => result?,
            }
            let read = match self {
                Self::Tcp(stream) => stream.read(buf),
                Self::Unix(stream) => stream.read(buf),
            };
            match read {
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                other => return other,
            }
        }
    }

    fn write_all_deadline(&mut self, mut data: &[u8], deadline: Instant) -> io::Result<()> {
        while !data.is_empty() {
            self.set_write_timeout(Some(remaining(deadline)?))?;
            let written = match self {
                Self::Tcp(stream) => stream.write(data),
                Self::Unix(stream) => stream.write(data),
            };
            match written {
                Ok(0) => {
                    return Err(io::Error::new(
                        io::ErrorKind::WriteZero,
                        "failed to write request to local OpenAI endpoint",
                    ));
                }
                Ok(n) => data = &data[n..],
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) => return Err(err),
            }
        }
        Ok(())
    }
}

fn read_http_response(stream: &mut EndpointStream, deadline: Instant) -> Result<(u16, Vec<u8>)> {
    let mut raw = Vec::new();
    let mut scratch = [0_u8; 8192];
    let header_end = loop {
        if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
            break pos;
        }
        ensure!(
            raw.len() < MAX_RESPONSE_HEADERS,
            "local OpenAI response headers exceeded limit"
        );
        let n = stream.read_chunk(&mut scratch, deadline)?;
        ensure!(n > 0, "unexpected EOF while reading local OpenAI headers");
        raw.extend_from_slice(&scratch[..n]);
    };

    let header_str = std::str::from_utf8(&raw[..header_end])
        .context("local OpenAI response headers are not valid UTF-8")?;
    let mut lines = header_str.split("\r\n");
    let status_line = lines
        .next()
        .context("missing HTTP status line from local OpenAI endpoint")?;
    let mut status_parts = status_line.split_whitespace();
    let version = status_parts.next().unwrap_or_default();
    ensure!(
        version == "HTTP/1.1" || version == "HTTP/1.0",
        "unsupported HTTP version '{version}' from local OpenAI endpoint"
    );
    let status: u16 = status_parts
        .next()
        .context("missing HTTP status code from local OpenAI endpoint")?
        .parse()
        .context("invalid HTTP status code from local OpenAI endpoint")?;
    ensure!(
        !(300..=399).contains(&status),
        "local OpenAI endpoint returned HTTP {status} redirect; redirects are rejected"
    );

    let mut is_chunked = false;
    let mut content_length: Option<usize> = None;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let name = name.trim();
        let value = value.trim();
        if name.eq_ignore_ascii_case("transfer-encoding") {
            for token in value.split(',').map(str::trim).filter(|t| !t.is_empty()) {
                if token.eq_ignore_ascii_case("chunked") {
                    is_chunked = true;
                } else if !token.eq_ignore_ascii_case("identity") {
                    bail!("unsupported Transfer-Encoding '{token}' from local OpenAI endpoint");
                }
            }
        } else if name.eq_ignore_ascii_case("content-length") {
            ensure!(
                !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()),
                "invalid Content-Length header '{value}'"
            );
            let parsed: usize = value.parse().context("Content-Length overflow")?;
            if let Some(prev) = content_length {
                ensure!(prev == parsed, "conflicting Content-Length headers");
            }
            content_length = Some(parsed);
        }
    }

    let rest = raw.split_off(header_end + 4);
    let body = if is_chunked {
        read_chunked_body(stream, rest, deadline)?
    } else if let Some(expected) = content_length {
        read_fixed_body(stream, rest, expected, deadline)?
    } else {
        read_eof_body(stream, rest, deadline)?
    };
    Ok((status, body))
}

fn read_fixed_body(
    stream: &mut EndpointStream,
    mut buf: Vec<u8>,
    expected: usize,
    deadline: Instant,
) -> Result<Vec<u8>> {
    ensure!(
        expected <= MAX_RESPONSE_BODY,
        "local OpenAI response exceeded 32 MiB body cap"
    );
    ensure!(
        buf.len() <= expected,
        "local OpenAI response body exceeded Content-Length"
    );
    let mut scratch = [0_u8; 8192];
    while buf.len() < expected {
        let want = (expected - buf.len()).min(scratch.len());
        let n = stream.read_chunk(&mut scratch[..want], deadline)?;
        ensure!(n > 0, "truncated local OpenAI response body");
        buf.extend_from_slice(&scratch[..n]);
    }
    Ok(buf)
}

fn read_eof_body(
    stream: &mut EndpointStream,
    mut buf: Vec<u8>,
    deadline: Instant,
) -> Result<Vec<u8>> {
    ensure!(
        buf.len() <= MAX_RESPONSE_BODY,
        "local OpenAI response exceeded 32 MiB body cap"
    );
    let mut scratch = [0_u8; 8192];
    loop {
        let n = stream.read_chunk(&mut scratch, deadline)?;
        if n == 0 {
            break;
        }
        ensure!(
            buf.len().saturating_add(n) <= MAX_RESPONSE_BODY,
            "local OpenAI response exceeded 32 MiB body cap"
        );
        buf.extend_from_slice(&scratch[..n]);
    }
    Ok(buf)
}

fn read_chunked_body(
    stream: &mut EndpointStream,
    mut buf: Vec<u8>,
    deadline: Instant,
) -> Result<Vec<u8>> {
    let mut cursor = 0usize;
    let mut decoded = Vec::new();
    let mut scratch = [0_u8; 8192];

    let read_more = |stream: &mut EndpointStream, buf: &mut Vec<u8>, scratch: &mut [u8; 8192]| {
        let n = stream.read_chunk(scratch, deadline)?;
        if n > 0 {
            buf.extend_from_slice(&scratch[..n]);
        }
        Ok::<usize, anyhow::Error>(n)
    };

    loop {
        let line_end = loop {
            if let Some(rel) = buf[cursor..].windows(2).position(|w| w == b"\r\n") {
                break cursor + rel;
            }
            ensure!(
                buf.len() - cursor <= MAX_CHUNK_LINE,
                "malformed chunked response size line"
            );
            let n = read_more(stream, &mut buf, &mut scratch)?;
            ensure!(n > 0, "unexpected EOF while reading chunk size");
        };
        let line = std::str::from_utf8(&buf[cursor..line_end])
            .context("chunk size line is not valid UTF-8")?;
        let hex = line.split(';').next().unwrap_or("").trim();
        ensure!(
            !hex.is_empty() && hex.bytes().all(|b| b.is_ascii_hexdigit()),
            "invalid chunked transfer size '{hex}'"
        );
        let size = usize::from_str_radix(hex, 16).context("chunk size overflow")?;
        cursor = line_end + 2;

        if size == 0 {
            // Drain optional trailer headers until the terminating empty line.
            let mut trailer_bytes = 0usize;
            loop {
                let trailer_end = loop {
                    if let Some(rel) = buf[cursor..].windows(2).position(|w| w == b"\r\n") {
                        break Some(cursor + rel);
                    }
                    ensure!(
                        trailer_bytes + (buf.len() - cursor) <= MAX_TRAILER_BYTES,
                        "chunked response trailers exceeded limit"
                    );
                    let n = read_more(stream, &mut buf, &mut scratch)?;
                    if n == 0 {
                        break None;
                    }
                };
                match trailer_end {
                    None => break,
                    Some(end) if end == cursor => break,
                    Some(end) => {
                        trailer_bytes += (end - cursor) + 2;
                        ensure!(
                            trailer_bytes <= MAX_TRAILER_BYTES,
                            "chunked response trailers exceeded limit"
                        );
                        cursor = end + 2;
                    }
                }
            }
            break;
        }

        ensure!(
            decoded.len().saturating_add(size) <= MAX_RESPONSE_BODY,
            "local OpenAI chunked response exceeded 32 MiB body cap"
        );
        let need = size.checked_add(2).context("chunk size overflow")?;
        while buf.len() - cursor < need {
            let n = read_more(stream, &mut buf, &mut scratch)?;
            ensure!(n > 0, "truncated chunked response body");
        }
        decoded.extend_from_slice(&buf[cursor..cursor + size]);
        ensure!(
            &buf[cursor + size..cursor + size + 2] == b"\r\n",
            "missing CRLF after chunk payload"
        );
        cursor += need;

        if cursor >= 65_536 || cursor == buf.len() {
            buf.drain(..cursor);
            cursor = 0;
        }
    }

    Ok(decoded)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{BufRead, BufReader},
        net::TcpListener,
        os::unix::net::UnixListener,
        sync::Arc,
        thread,
    };

    fn read_test_request(stream: &mut impl Read) -> (String, Vec<String>, Vec<u8>) {
        let mut reader = BufReader::new(stream);
        let mut request_line = String::new();
        reader.read_line(&mut request_line).unwrap();
        let mut headers = Vec::new();
        let mut content_length = 0usize;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let trimmed = line.trim_end_matches(['\r', '\n']);
            if trimmed.is_empty() {
                break;
            }
            if let Some((name, val)) = trimmed.split_once(':')
                && name.trim().eq_ignore_ascii_case("content-length")
            {
                content_length = val.trim().parse().unwrap();
            }
            headers.push(trimmed.to_owned());
        }
        let mut body = vec![0_u8; content_length];
        if content_length > 0 {
            reader.read_exact(&mut body).unwrap();
        }
        (request_line.trim().to_owned(), headers, body)
    }

    fn spawn_tcp_server(
        count: usize,
        handler: impl Fn(String, Vec<String>, Vec<u8>) -> Vec<u8> + Send + Sync + 'static,
    ) -> (u16, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let handler = Arc::new(handler);
        let handle = thread::spawn(move || {
            for _ in 0..count {
                let (mut stream, _) = listener.accept().unwrap();
                let (req_line, headers, body) = read_test_request(&mut stream);
                let reply = handler(req_line, headers, body);
                stream.write_all(&reply).unwrap();
                let _ = stream.flush();
            }
        });
        (port, handle)
    }

    #[test]
    fn validate_loopback_url_enforces_strict_boundary() {
        assert!(matches!(
            validate_loopback_url("http://127.0.0.1:8000/v1").unwrap(),
            ValidatedEndpoint::Http { ref host, ref base_path, .. }
                if host == "127.0.0.1" && base_path == "/v1"
        ));
        assert!(matches!(
            validate_loopback_url("http://127.0.0.1:8000/v1/").unwrap(),
            ValidatedEndpoint::Http { ref base_path, .. } if base_path == "/v1"
        ));
        assert!(matches!(
            validate_loopback_url("http://[::1]:11434").unwrap(),
            ValidatedEndpoint::Http { ref host, ref base_path, .. }
                if host == "[::1]" && base_path.is_empty()
        ));
        assert!(matches!(
            validate_loopback_url("http://localhost:8080/api").unwrap(),
            ValidatedEndpoint::Http { ref host, ref base_path, .. }
                if host == "localhost" && base_path == "/api"
        ));

        for rejected in [
            "",
            "https://api.openai.com/v1",
            "https://127.0.0.1:8000/v1",
            "http://192.168.1.10:8000/v1",
            "http://10.0.0.1:8000/v1",
            "http://0.0.0.0:8000/v1",
            "http://127.0.0.2:8000/v1",
            "http://example.com/v1",
            "http://localhost.evil.com/v1",
            "http://user:pass@127.0.0.1:8000/v1",
            "http://127.0.0.1:8000/v1?foo=bar",
            "http://127.0.0.1:8000/v1#frag",
            "http://127.0.0.1:0/v1",
            "http://127.0.0.1:8000/v1/../secret",
            "http://127.0.0.1:8000/v1\r\nX-Injected: 1",
            "ftp://127.0.0.1/v1",
            "unix://relative.sock",
            "unix:///",
            "unix:///tmp/../etc/passwd",
        ] {
            assert!(
                validate_loopback_url(rejected).is_err(),
                "expected URL to be rejected: {rejected:?}"
            );
        }

        // Syntactically valid missing Unix socket path is allowed at config/worker
        // construction (cold-start safe) and rejected lazily on transport connect.
        let missing_unix = "unix:///nonexistent/lumen-no-such.sock";
        assert!(matches!(
            validate_loopback_url(missing_unix).unwrap(),
            ValidatedEndpoint::Unix { ref socket_path, .. }
                if socket_path == Path::new("/nonexistent/lumen-no-such.sock")
        ));
        let missing_worker = LocalOpenAiWorker::new(&LocalOpenAiConfig {
            url: missing_unix.into(),
            model: "bge-m3".into(),
        })
        .unwrap()
        .with_api_key(None);
        assert!(missing_worker.check_reachable().is_err());
        assert!(missing_worker.list_models().is_err());
        assert!(missing_worker.probe().is_err());
        assert!(missing_worker.encode_query("hello").is_err());
        assert!(missing_worker.encode_passage("hello").is_err());
        assert!(missing_worker.encode_passages(&["hello"]).is_err());

        // Route joining handles /v1 suffix without duplicating /v1/v1.
        let ep_v1 = validate_loopback_url("http://127.0.0.1:8000/v1/").unwrap();
        assert_eq!(ep_v1.route("models"), "/v1/models");
        assert_eq!(ep_v1.route("embeddings"), "/v1/embeddings");
        let ep_root = validate_loopback_url("http://127.0.0.1:8000").unwrap();
        assert_eq!(ep_root.route("models"), "/v1/models");
        let ep_custom = validate_loopback_url("http://127.0.0.1:8000/openai/v1").unwrap();
        assert_eq!(ep_custom.route("embeddings"), "/openai/v1/embeddings");
    }

    #[test]
    fn tcp_list_models_probe_chunked_and_auth_header_roundtrip() {
        let (port, handle) = spawn_tcp_server(3, |req_line, headers, body| {
            let has_auth = headers
                .iter()
                .any(|h| h == "Authorization: Bearer secret-token");
            assert!(has_auth, "expected Authorization header, got {headers:?}");

            if req_line == "GET /v1/models HTTP/1.1" {
                let payload = r#"{"data":[{"id":"bge-m3"},{"id":"nomic-embed"},{"id":"bge-m3"},{"id":"  "}]}"#;
                // Chunked transfer encoding split across two chunks.
                let part1 = &payload[..24];
                let part2 = &payload[24..];
                return format!(
                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n{:x}\r\n{}\r\n{:x}\r\n{}\r\n0\r\n\r\n",
                    part1.len(),
                    part1,
                    part2.len(),
                    part2
                )
                .into_bytes();
            }
            if req_line == "POST /v1/embeddings HTTP/1.1" {
                let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
                assert_eq!(json["model"], "bge-m3");
                let inputs = json["input"].as_array().unwrap();
                let mut rows = Vec::new();
                for (i, _) in inputs.iter().enumerate() {
                    // Return unnormalized 16-d vector; client must L2-normalize it.
                    let mut v = vec![0.0_f32; 16];
                    v[0] = 3.0;
                    v[1] = 4.0;
                    rows.push(serde_json::json!({"index": i, "embedding": v}));
                }
                let payload = serde_json::to_string(&serde_json::json!({"data": rows})).unwrap();
                return format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
                    payload.len(),
                    payload
                )
                .into_bytes();
            }
            b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".to_vec()
        });

        let config = LocalOpenAiConfig {
            url: format!("http://127.0.0.1:{port}/v1"),
            model: "bge-m3".into(),
        };
        let worker = LocalOpenAiWorker::new(&config)
            .unwrap()
            .with_api_key(Some("secret-token".into()));
        assert_eq!(worker.list_models().unwrap(), ["bge-m3", "nomic-embed"]);
        assert_eq!(
            worker.probe().unwrap(),
            ("openai-local:bge-m3@16".into(), 16)
        );
        let q = worker.encode_query("hello world").unwrap();
        assert_eq!(q.len(), 16);
        assert!((q[0] - 0.6).abs() < 1e-5 && (q[1] - 0.8).abs() < 1e-5);
        handle.join().unwrap();
    }

    #[test]
    fn encode_passages_bisects_on_400_context_limit_and_preserves_neighbors() {
        let (port, handle) = spawn_tcp_server(5, |_req_line, _headers, body| {
            let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
            let inputs: Vec<&str> = json["input"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap())
                .collect();
            if inputs.iter().any(|s| s.contains("OVERFLOW")) {
                let err = r#"{"error":{"message":"maximum context length exceeded"}}"#;
                return format!(
                    "HTTP/1.1 400 Bad Request\r\nContent-Length: {}\r\n\r\n{}",
                    err.len(),
                    err
                )
                .into_bytes();
            }
            let data: Vec<_> = inputs
                .iter()
                .enumerate()
                .map(|(i, text)| {
                    let mut v = vec![0.0_f32; 8];
                    v[0] = 1.0;
                    v[1] = if text.contains("alpha") { 1.0 } else { 0.0 };
                    serde_json::json!({"index": i, "embedding": v})
                })
                .collect();
            let payload = serde_json::to_string(&serde_json::json!({"data": data})).unwrap();
            format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{}",
                payload.len(),
                payload
            )
            .into_bytes()
        });

        let config = LocalOpenAiConfig {
            url: format!("http://127.0.0.1:{port}"),
            model: "local-embed".into(),
        };
        let worker = LocalOpenAiWorker::new(&config).unwrap().with_api_key(None);
        let results = worker
            .encode_passages(&["alpha doc", "OVERFLOW chunk", "beta doc"])
            .unwrap();
        assert_eq!(results.len(), 3);
        assert!(results[0].is_some());
        assert!(results[1].is_none());
        assert!(results[2].is_some());
        handle.join().unwrap();
    }

    #[test]
    fn http_302_redirect_is_strictly_rejected() {
        let (port, handle) = spawn_tcp_server(1, |_req_line, _headers, _body| {
            b"HTTP/1.1 302 Found\r\nLocation: http://evil.example.com/v1/models\r\nContent-Length: 0\r\n\r\n".to_vec()
        });
        let config = LocalOpenAiConfig {
            url: format!("http://127.0.0.1:{port}/v1"),
            model: "test-model".into(),
        };
        let worker = LocalOpenAiWorker::new(&config).unwrap().with_api_key(None);
        let err = worker.list_models().unwrap_err();
        assert!(
            err.to_string().contains("302") && err.to_string().contains("redirect"),
            "unexpected error: {err:#}"
        );
        handle.join().unwrap();
    }

    #[test]
    fn unix_socket_endpoint_roundtrip_and_symlink_rejection() {
        let root = fs::canonicalize(std::env::temp_dir())
            .unwrap()
            .join(format!("lumen-openai-unix-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let sock_path = root.join("embed.sock");
        let missing_path = root.join("missing.sock");
        let link_path = root.join("link.sock");
        let regular_path = root.join("regular.txt");
        fs::write(&regular_path, "not a socket").unwrap();

        let listener = UnixListener::bind(&sock_path).unwrap();
        std::os::unix::fs::symlink(&sock_path, &link_path).unwrap();

        // Missing socket, regular file, and symlink-to-socket are accepted at
        // path-syntax validation time (cold-start safe) and MUST all be rejected
        // lazily on every transport operation right before UnixStream::connect.
        for bad_path in [&missing_path, &regular_path, &link_path] {
            let bad_url = format!("unix://{}", bad_path.display());
            assert!(validate_loopback_url(&bad_url).is_ok());
            let bad_worker = LocalOpenAiWorker::new(&LocalOpenAiConfig {
                url: bad_url,
                model: "unix-embed".into(),
            })
            .unwrap()
            .with_api_key(None);
            assert!(bad_worker.check_reachable().is_err());
            assert!(bad_worker.list_models().is_err());
            assert!(bad_worker.probe().is_err());
            assert!(bad_worker.encode_query("hello").is_err());
            assert!(bad_worker.encode_passage("hello").is_err());
        }

        let handle = thread::spawn(move || {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                let (req_line, _headers, body) = read_test_request(&mut stream);
                let reply = if req_line == "GET /v1/models HTTP/1.1" {
                    let payload = r#"{"data":[{"id":"unix-embed"}]}"#;
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{}",
                        payload.len(),
                        payload
                    )
                } else {
                    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
                    assert_eq!(json["model"], "unix-embed");
                    let v = [1.0_f32, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
                    let payload = serde_json::to_string(
                        &serde_json::json!({"data":[{"index":0,"embedding":v}]}),
                    )
                    .unwrap();
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{}",
                        payload.len(),
                        payload
                    )
                };
                stream.write_all(reply.as_bytes()).unwrap();
                let _ = stream.flush();
            }
        });

        let url = format!("unix://{}", sock_path.display());
        assert!(matches!(
            validate_loopback_url(&url).unwrap(),
            ValidatedEndpoint::Unix { ref socket_path, .. } if socket_path == &sock_path
        ));
        let config = LocalOpenAiConfig {
            url,
            model: "unix-embed".into(),
        };
        let worker = LocalOpenAiWorker::new(&config).unwrap().with_api_key(None);
        assert_eq!(worker.list_models().unwrap(), ["unix-embed"]);
        assert_eq!(
            worker.probe().unwrap(),
            ("openai-local:unix-embed@8".into(), 8)
        );
        handle.join().unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn canonical_model_id_preserves_safe_ascii_and_prevents_collisions() {
        // Verify pure-Rust SHA-256 prefix against standard NIST test vectors.
        assert_eq!(sha256_hex_12(b""), "e3b0c44298fc");
        assert_eq!(sha256_hex_12(b"abc"), "ba7816bf8f01");
        assert_eq!(
            sha256_hex_12(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d206"
        );

        // Safe ASCII names <= 200 bytes keep exact backward-compatible form.
        for safe in ["bge-m3", "BAAI/bge-m3:latest+fp16", "foo_bar_", "a.b-c"] {
            assert_eq!(sanitize_model_name(safe), safe);
            assert_eq!(
                canonical_model_id(safe, 768),
                format!("openai-local:{safe}@768")
            );
            assert!(!sanitize_model_name(safe).contains('~'));
        }
        let exact_200 = "a".repeat(200);
        assert_eq!(sanitize_model_name(&exact_200), exact_200);
        assert_eq!(
            canonical_model_id(&exact_200, 16),
            format!("openai-local:{exact_200}@16")
        );

        // Distinct raw names that sanitize to the same prefix MUST produce distinct IDs.
        let candidates = [
            "foo_bar", "foo bar", "foo  bar", "foo@bar", "foo~bar", "foo(bar)", "foo_bar!",
            "foo_bar?",
        ];
        let mut seen = std::collections::HashSet::new();
        for raw in candidates {
            let sanitized = sanitize_model_name(raw);
            assert!(
                sanitized.len() <= MAX_SANITIZED_MODEL_LEN,
                "sanitized name exceeded bound: {sanitized}"
            );
            let id = canonical_model_id(raw, 16);
            assert!(seen.insert(id.clone()), "collision for {raw:?} -> {id}");
        }
        // Safe name stays exact; sanitized ones carry ~<12-hex>.
        assert_eq!(canonical_model_id("foo_bar", 16), "openai-local:foo_bar@16");
        let space_id = canonical_model_id("foo bar", 16);
        assert!(
            space_id.starts_with("openai-local:foo_bar~") && space_id.ends_with("@16"),
            "unexpected hashed id: {space_id}"
        );

        // Names longer than 200 bytes sharing the same 200-char prefix MUST NOT collide
        // and stay bounded to 200 bytes before @<dims>.
        let long_a = format!("{}1", "m".repeat(200));
        let long_b = format!("{}2", "m".repeat(200));
        let san_a = sanitize_model_name(&long_a);
        let san_b = sanitize_model_name(&long_b);
        assert!(san_a.len() <= MAX_SANITIZED_MODEL_LEN);
        assert!(san_b.len() <= MAX_SANITIZED_MODEL_LEN);
        assert_ne!(san_a, san_b);
        assert_ne!(san_a, exact_200);

        // Non-ASCII-only distinct model names stay non-empty and collision-free.
        let zh = canonical_model_id("中文模型", 16);
        let ja = canonical_model_id("日本語モデル", 16);
        assert_ne!(zh, ja);
        assert!(zh.starts_with("openai-local:~") && zh.ends_with("@16"));
        assert!(ja.starts_with("openai-local:~") && ja.ends_with("@16"));

        // Empty / whitespace-only still sanitizes to empty.
        assert!(sanitize_model_name("   ").is_empty());
    }

    #[test]
    fn probe_with_timeout_caps_unresponsive_loopback_server() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let (done_tx, done_rx) = std::sync::mpsc::channel::<()>();
        let server = thread::spawn(move || {
            if let Ok((_stream, _)) = listener.accept() {
                // Hold the connection open without writing a response until test ends.
                let _ = done_rx.recv_timeout(Duration::from_secs(5));
            }
        });
        let worker = LocalOpenAiWorker::new(&LocalOpenAiConfig {
            url: format!("http://127.0.0.1:{port}/v1"),
            model: "slow-model".into(),
        })
        .unwrap()
        .with_api_key(None);

        let started = Instant::now();
        let err = worker
            .probe_with_timeout(Duration::from_millis(200))
            .unwrap_err();
        let elapsed = started.elapsed();
        let _ = done_tx.send(());
        server.join().unwrap();

        assert!(
            elapsed < Duration::from_secs(2),
            "probe_with_timeout exceeded bound ({elapsed:?}): {err:#}"
        );
    }
}
