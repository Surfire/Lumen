"""Optional Lumen BGE worker. Supply a verified public snapshot and local Python runtime.

Tested with Python 3.12, torch 2.12.0, transformers 4.57.3, tokenizers 0.22.2,
and safetensors 0.7.0. This program does not install or retrieve assets.
"""
import argparse
import hashlib
from importlib.metadata import version
import json
import os
from pathlib import Path
import stat
import sys

PROTOCOL = 1
MAX_LINE = 16_384
MAX_TOKENS = 512
PROFILES = {
    "zh": {
        "model": "BAAI/bge-small-zh-v1.5",
        "revision": "7999e1d3359715c523056ef9478215996d62a620",
        "dimensions": 512,
        "query_prefix": "为这个句子生成表示以用于检索相关文章：",
        "assets": {
            "config.json": (776, "3853a7979202c348751b753e36f579c41d8da7d36af617d3d907e1fc9b441f2a"),
            "tokenizer.json": (439125, "48cea5d44424912a6fd1ea647bf4fe50b55ab8b1e5879c3275f80e339e8fae26"),
            "model.safetensors": (95827648, "354763b9b1357bc9c44f62c6be2276321081ed2567773608c0d0785b61d5a026"),
        },
    },
    "en": {
        "model": "BAAI/bge-small-en-v1.5",
        "revision": "5c38ec7c405ec4b44b94cc5a9bb96e735b38267a",
        "dimensions": 384,
        "query_prefix": "Represent this sentence for searching relevant passages: ",
        "assets": {
            "config.json": (743, "094f8e891b932f2000c92cfc663bac4c62069f5d8af5b5278c4306aef3084750"),
            "tokenizer.json": (711396, "d241a60d5e8f04cc1b2b3e9ef7a4921b27bf526d9f6050ab90f9267a1f9e5c66"),
            "model.safetensors": (133466304, "3c9f31665447c8911517620762200d2245a2518d6e7208acc78cd9db317e21ad"),
        },
    },
}


def read_asset(directory, name, expected):
    size, digest = expected
    path = (directory / name).resolve(strict=True)
    info = path.stat()
    if (not stat.S_ISREG(info.st_mode) or info.st_size != size
            or getattr(info, "st_flags", 0) & 0x40000000):
        raise ValueError(f"{name} must be a local regular file from the pinned snapshot")
    # O_NOFOLLOW_ANY replaces O_NOFOLLOW on Darwin and also checks ancestors.
    nofollow = 0x20000000 if sys.platform == "darwin" else os.O_NOFOLLOW
    flags = os.O_RDONLY | os.O_NONBLOCK | nofollow
    with os.fdopen(os.open(path, flags), "rb") as stream:
        opened = os.fstat(stream.fileno())
        if (not stat.S_ISREG(opened.st_mode) or opened.st_size != size
                or getattr(opened, "st_flags", 0) & 0x40000000
                or (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino)):
            raise ValueError(f"{name} changed or is not a local regular file")
        content = stream.read(size + 1)
    if len(content) != size or hashlib.sha256(content).hexdigest() != digest:
        raise ValueError(f"{name} does not match the pinned snapshot SHA-256")
    return content


def load_encoder(assets, dimensions):
    import torch
    from safetensors.torch import load
    from tokenizers import Tokenizer
    from transformers import BertConfig, BertModel

    torch.set_num_threads(2)
    config = BertConfig.from_dict(json.loads(assets["config.json"]))
    if config.hidden_size != dimensions:
        raise ValueError("unexpected BGE model dimension")
    model = BertModel(config)
    missing, extra = model.load_state_dict(load(assets.pop("model.safetensors")), strict=False)
    if missing or set(extra) - {"embeddings.position_ids"}:
        raise ValueError("unexpected BGE model tensors")
    model.eval()
    tokenizer = Tokenizer.from_str(assets["tokenizer.json"].decode("utf-8"))
    tokenizer.enable_truncation(max_length=MAX_TOKENS)

    def encode(text):
        token = tokenizer.encode(text)
        if all(token.special_tokens_mask):
            return None
        with torch.inference_mode():
            hidden = model(
                input_ids=torch.tensor([token.ids]),
                attention_mask=torch.tensor([token.attention_mask]),
                token_type_ids=torch.tensor([token.type_ids]),
            ).last_hidden_state
            embedding = torch.nn.functional.normalize(hidden[:, 0], dim=1)
        return embedding[0].tolist()

    return encode


def emit(record):
    print(json.dumps(record, allow_nan=False, separators=(",", ":")), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--language", choices=PROFILES, required=True)
    args = parser.parse_args()
    profile = PROFILES[args.language]
    os.environ.update(
        HF_HUB_OFFLINE="1",
        TRANSFORMERS_OFFLINE="1",
        HF_HUB_DISABLE_TELEMETRY="1",
        TOKENIZERS_PARALLELISM="false",
    )
    runtime = {name: version(name) for name in ("torch", "transformers", "tokenizers", "safetensors")}
    assets = {name: read_asset(args.model_dir, name, expected)
              for name, expected in profile["assets"].items()}
    identity = {
        "protocol": PROTOCOL,
        "profile": profile,
        "tokens": MAX_TOKENS,
        "python": sys.version_info[:3],
        "runtime": runtime,
        "worker": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }
    fingerprint = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    encode = load_encoder(assets, profile["dimensions"])
    emit({"protocol": PROTOCOL, "fingerprint": fingerprint,
          "language": args.language, "dimensions": profile["dimensions"]})
    stdin = sys.stdin.buffer
    while line := stdin.readline(MAX_LINE + 1):
        if len(line) > MAX_LINE or not line.endswith(b"\n"):
            raise ValueError("BGE request exceeds the frame limit")
        request = json.loads(line)
        role, text = request["role"], request["text"]
        if role not in ("passage", "query") or not isinstance(text, str) or not text.strip():
            raise ValueError("invalid BGE request")
        vector = encode(profile["query_prefix"] + text if role == "query" else text)
        emit({"unencodable": True} if vector is None else {"vector": vector})


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"offline BGE worker: {error}", file=sys.stderr)
        sys.exit(1)
