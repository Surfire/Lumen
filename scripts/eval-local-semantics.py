"""Replay synthetic semantic retrieval cases with local assets and fixed thresholds."""
import argparse
from collections import defaultdict
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys

# Apply these to this evaluation process and its children only.
os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1",
                  HF_HUB_DISABLE_TELEMETRY="1", TOKENIZERS_PARALLELISM="false")
import numpy as np

REPO = Path(__file__).resolve().parents[1]
FIXTURE = REPO / "tests/fixtures/semantic-cases.json"
WORKER = REPO / "scripts/local-bge.py"
BASE_ZH_WEIGHTS = (
    409138989, "731cf5d88ed555a21ff2f2d9fa4db43b10489173ddd9178db3eecfd7a2bae044"
)
MINILM_WEIGHTS = (
    118620017, "1825907d6c1a9001ff78124780bbde20a614a8c3df3b63409cf3c72c6fe5c8b4"
)
MINILM_TOKENIZER = (
    17082660, "62c24cdc13d4c9952d63718d6c9fa4c287974249e16b7ade6d5a85e7bbb75626"
)


def verified(path, specification, keep=False):
    size, digest = specification
    if path.stat().st_size != size:
        raise ValueError(f"unexpected size for {path.name}")
    with path.open("rb") as file:
        if keep:
            data = file.read(size + 1)
            actual = hashlib.sha256(data).hexdigest()
        else:
            data = None
            actual = hashlib.file_digest(file, "sha256").hexdigest()
    if actual != digest:
        raise ValueError(f"unexpected SHA-256 for {path.name}")
    return data


def encode_pair(args, documents, queries):
    if args.encoder == "apple":
        def encode(texts):
            return [
                json.loads(subprocess.check_output(
                    [args.apple_helper, args.language], input=text.encode(), timeout=15))
                for text in texts
            ]
        return encode(documents), encode(queries)
    if args.encoder == "bge-small":
        with subprocess.Popen(
            [sys.executable, "-I", WORKER, "--model-dir", args.snapshot, "--language", args.language],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        ) as process:
            hello = json.loads(process.stdout.readline())
            if hello["protocol"] != 1:
                raise RuntimeError("unexpected BGE worker protocol")

            def encode(role, texts):
                result = []
                for text in texts:
                    process.stdin.write(json.dumps({"role": role, "text": text}) + "\n")
                    process.stdin.flush()
                    result.append(json.loads(process.stdout.readline())["vector"])
                return result

            ordered = encode("passage", documents), encode("query", queries)
            process.stdin.close()
            if process.wait(timeout=30) != 0:
                raise RuntimeError("BGE worker exited with an error")
            return ordered

    # Reproduce the earlier Chinese base comparison only. Production uses
    # verified safetensors in the isolated worker above.
    import torch
    from transformers import AutoConfig, AutoModel, AutoTokenizer

    torch.set_num_threads(2)
    base = args.snapshot
    verified(base / "config.json", (998, "6675c035d945dffc89f77a04a254b87cc193a9185a098bb505fe4963b6ddbac1"))
    verified(base / "tokenizer.json", (439124, "7dfbf1966ebf99d471c3796e9b457329d2b2182b817e144f1e904b957745c839"))
    verified(base / "pytorch_model.bin", BASE_ZH_WEIGHTS)
    tokenizer = AutoTokenizer.from_pretrained(base, local_files_only=True, trust_remote_code=False)
    config = AutoConfig.from_pretrained(base, local_files_only=True, trust_remote_code=False)
    model = AutoModel.from_config(config, trust_remote_code=False)
    state = torch.load(base / "pytorch_model.bin", weights_only=True, mmap=True, map_location="cpu")
    missing, extra = model.load_state_dict(state, strict=False)
    if missing or set(extra) - {"embeddings.position_ids"}:
        raise ValueError("unexpected BGE-base tensors")
    model.eval()

    def encode(texts):
        groups = []
        with torch.inference_mode():
            for pos in range(0, len(texts), 16):
                batch = tokenizer(texts[pos:pos+16], truncation=True, max_length=512,
                                  padding=True, return_tensors="pt")
                groups.append(model(**batch).last_hidden_state[:, 0])
        return torch.cat(groups).numpy()

    instruction = "为这个句子生成表示以用于检索相关文章："
    return encode(documents), encode([instruction + text for text in queries])


def rerank(directory, documents, queries, rankings):
    import onnxruntime as ort
    from tokenizers import Tokenizer

    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    graph = verified(directory / "model_qint8_arm64.onnx", MINILM_WEIGHTS, keep=True)
    session = ort.InferenceSession(graph, sess_options=options,
                                   providers=["CPUExecutionProvider"])
    config = verified(directory / "tokenizer.json", MINILM_TOKENIZER, keep=True)
    tokenizer = Tokenizer.from_str(config.decode())
    tokenizer.enable_padding(pad_id=tokenizer.token_to_id("<pad>"), pad_token="<pad>")
    tokenizer.enable_truncation(max_length=512)
    for query, candidates in zip(queries, rankings):
        pairs = tokenizer.encode_batch([(query, documents[index]) for index, _ in candidates])
        result, = session.run(None, {
            "input_ids": np.asarray([item.ids for item in pairs], dtype=np.int64),
            "attention_mask": np.asarray([item.attention_mask for item in pairs], dtype=np.int64),
        })
        if result.shape != (len(pairs), 1) or not np.isfinite(result).all():
            raise ValueError("unexpected MiniLM output")
        yield sorted(zip([item[0] for item in candidates], result[:, 0]), key=lambda row: -row[1])


def summarize(queries, rankings, cutoff, margin):
    ranks, false_hits = [], defaultdict(list)
    for row, ranking in zip(queries, rankings):
        gap = ranking[0][1] - ranking[1][1] if len(ranking) > 1 else math.inf
        hits = [index for index, score in ranking if score >= cutoff] if gap >= margin else []
        answer = row["expected"]
        if answer is None:
            false_hits[row["kind"]].append(bool(hits))
        else:
            ranks.append(hits.index(answer) + 1 if answer in hits else 0)
    return {
        "with_answer": len(ranks),
        "hit_at_1": ranks.count(1),
        "hit_at_5": sum(0 < rank <= 5 for rank in ranks),
        "mrr": round(sum(1 / rank for rank in ranks if rank) / len(ranks), 3),
        "false_positives": {name: [sum(values), len(values)] for name, values in false_hits.items()},
    }


def unit_vectors(rows):
    rows = np.asarray(rows, dtype=np.float32)
    lengths = np.linalg.norm(rows, axis=1, keepdims=True)
    if not np.isfinite(rows).all() or not (lengths > 0).all():
        raise ValueError("invalid embedding")
    return rows / lengths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--language", choices=("zh", "en"), required=True)
    parser.add_argument("--encoder", choices=("apple", "bge-small", "bge-base-zh"), required=True)
    parser.add_argument("--snapshot", type=Path)
    parser.add_argument("--apple-helper", type=Path)
    parser.add_argument("--reranker", type=Path, help="local verified MiniLM ONNX assets")
    parser.add_argument("--suite", choices=("calibration", "fixed", "near"), default="fixed")
    parser.add_argument("--cutoff", type=float, required=True)
    parser.add_argument("--margin", type=float, default=0)
    args = parser.parse_args()
    if args.encoder == "apple" and not args.apple_helper:
        parser.error("Apple evaluation requires --apple-helper")
    if args.encoder != "apple" and not args.snapshot:
        parser.error("BGE evaluation requires --snapshot")
    if args.encoder == "bge-base-zh" and args.language != "zh":
        parser.error("BGE-base-zh supports the Chinese evaluation profile only")

    cases = json.loads(FIXTURE.read_text())[args.suite][args.language]
    documents, queries = cases["documents"], cases["queries"]
    questions = [item["text"] for item in queries]
    docs, qs = encode_pair(args, documents, questions)
    scores = unit_vectors(qs) @ unit_vectors(docs).T
    rankings = [sorted(enumerate(row), key=lambda candidate: -candidate[1]) for row in scores]
    if args.reranker:
        ranks_at_10 = [row[:10] for row in rankings]
        rankings = list(rerank(args.reranker, documents, questions, ranks_at_10))
    print(json.dumps({
        "suite": args.suite, "encoder": args.encoder, "language": args.language,
        "reranked": bool(args.reranker), "cutoff": args.cutoff, "margin": args.margin,
        "unfiltered": summarize(queries, rankings, -math.inf, 0),
        "filtered": summarize(queries, rankings, args.cutoff, args.margin),
    }, indent=2))


if __name__ == "__main__":
    main()
