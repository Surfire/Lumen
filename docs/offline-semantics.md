# 离线语义候选

BGE 按语义相似度返回原文片段，CLI 将命中标记为 `semantic_candidate`。文件名和全文检索仍可独立使用。「原文已经回答问题」需要另外验证答案是否得到原文支持。下面的分数门槛只用于评估筛选效果，未用于自动作答。

## 一次安装

准备本机已有的 CPython 3.12、`uv`、已缓存的 Python wheels 和公开模型快照。安装器只读取显式指定的本地目录，核对模型、分词器和配置的固定 SHA-256，并用 `uv --offline` 创建隔离环境。可只安装一个语言。

```sh
python3 scripts/install-local-bge.py --zh-model "$zh_snapshot" --en-model "$en_snapshot"
```

默认资源目录是 `~/Library/Application Support/Lumen/Semantic`。其中 `runtime/bin/python3` 是隔离环境的解释器入口，仍依赖本机已安装的 CPython。模型放在 `models/zh` 和 `models/en`。安装器的 `--destination DIR` 对应 CLI 的 `--bge-home DIR`。[中文模型固定版本](https://huggingface.co/BAAI/bge-small-zh-v1.5/tree/7999e1d3359715c523056ef9478215996d62a620) · [英文模型固定版本](https://huggingface.co/BAAI/bge-small-en-v1.5/tree/5c38ec7c405ec4b44b94cc5a9bb96e735b38267a)

## 签名 app 接入

在签名前将 `scripts/local-bge.py` 复制到 `Contents/Resources`，与 `lumen` 放在一起。运行时和权重留在独立资源目录。launcher 用 Foundation `Process` 和参数数组直接调用 `lumen`，即可使用默认发现，无需激活虚拟环境、设置全局环境变量或启动服务。

```sh
"$lumen" model-status --language zh --verify
"$lumen" --db "$db" index --root "$fixture_root" --documents
"$lumen" --db "$db" embed --bge --language zh --max 32
"$lumen" --db "$db" query --mode semantic --bge --language zh -- "$term"
```

- `model-status` 只核对文件布局。`--verify` 还会启动 worker，核对资产散列并加载模型。异步执行并读取 JSON 的 `available`、`verified` 和 `diagnostic`。模型缺失也会返回状态 JSON，界面据此保持候选功能不可用。
- 针对同一个库和语言，后台串行跑 `embed` 批次。每批返回 `new_embeddings`、`skipped_chunks` 和 `has_more`，按 `has_more` 决定是否继续。已提交的片段可在取消后续跑。单个不可编码段会按模型版本跳过。
- 每个 SQLite 库只保留一套当前语义向量。切换语言、模型或 worker 后，下一次成功写入向量会替换旧向量，文件名和全文索引可继续使用。BGE 是显式选项，模型或运行时缺失会报告错误。

签名包复验可给临时库索引一份两段的合成 Markdown，再连续跑两次 `embed --max 1`。两批各应新增一个向量，`has_more` 依次为 `true` 和 `false`。最后查询第二段的改写，检查 `matched_by` 和返回的原文片段。

## 可复验的合成评估

[合成夹具](../tests/fixtures/semantic-cases.json) 分为独立校准组 `calibration`、原闸门 `fixed`、以及查询与文档同主题但原文缺少所问信息的 `near` 组。阈值先用校准组确定，再对保留组运行。`fixed` 含中文 30 条、英文 20 条有答案查询，每种语言各有 10 条无答案。`near` 每种语言各有 6 条有答案和 6 条无答案。MRR 的未命中按零计分。无答案误报表示至少返回一个候选。

下表每组依次为 **Hit@1 / Hit@5 / MRR / 无答案误报**。MiniLM 重排余弦前 10 个候选，表内分数阈值作用于重排 logit；其他行使用余弦分数。

| 原闸门 | 阈值 | 筛选前 | 筛选后 |
|---|---:|---|---|
| 中文 Apple 句向量 | 0.25 | 5/30 · 11/30 · .305 · 10/10 | 5/30 · 11/30 · .305 · 10/10 |
| 中文 BGE-small | 0.52 | 25/30 · 29/30 · .900 · 10/10 | 19/30 · 20/30 · .650 · 0/10 |
| 中文 BGE-base | 0.43 | 29/30 · 30/30 · .978 · 10/10 | 27/30 · 27/30 · .900 · 0/10 |
| 中文 BGE-base + MiniLM | −3.55 | 25/30 · 30/30 · .908 · 10/10 | 19/30 · 19/30 · .633 · 1/10 |
| 英文 Apple 句向量 | 0.25 | 11/20 · 16/20 · .684 · 10/10 | 11/20 · 15/20 · .653 · 7/10 |
| 英文 BGE-small | 0.66 | 19/20 · 20/20 · .975 · 10/10 | 7/20 · 7/20 · .350 · 0/10 |
| 英文 Apple + MiniLM | −0.15 | 15/20 · 20/20 · .854 · 10/10 | 0/20 · 0/20 · .000 · 0/10 |

| 同主题保留组 | 筛选前 | 筛选后 |
|---|---|---|
| 中文 BGE-small | 6/6 · 6/6 · 1.000 · 6/6 | 6/6 · 6/6 · 1.000 · 4/6 |
| 中文 BGE-base | 6/6 · 6/6 · 1.000 · 6/6 | 6/6 · 6/6 · 1.000 · 4/6 |
| 中文 BGE-base + MiniLM | 4/6 · 6/6 · .833 · 6/6 | 3/6 · 3/6 · .500 · 3/6 |
| 英文 BGE-small | 6/6 · 6/6 · 1.000 · 6/6 | 2/6 · 2/6 · .333 · 0/6 |
| 英文 Apple + MiniLM | 4/6 · 6/6 · .756 · 6/6 | 0/6 · 0/6 · .000 · 0/6 |

筛掉低分会漏掉原文确有答案的查询。中文对同主题无答案依然有明显误报。以上组合均未通过高置信答案门槛。

使用已安装环境的解释器运行脚本可以复验 BGE-small。将 `--suite fixed` 改为 `near` 可复验同主题组。

```sh
semantic_dir="$HOME/Library/Application Support/Lumen/Semantic"
semantic_python="$semantic_dir/runtime/bin/python3"
"$semantic_python" -I scripts/eval-local-semantics.py --suite fixed \
  --encoder bge-small --language zh --snapshot "$semantic_dir/models/zh" --cutoff 0.52
"$semantic_python" -I scripts/eval-local-semantics.py --suite fixed \
  --encoder bge-small --language en --snapshot "$semantic_dir/models/en" --cutoff 0.66
```

Apple 对照用 `--encoder apple --apple-helper "$apple_helper"` 和表中语言、阈值。中文 BGE-base 对照用 `--encoder bge-base-zh --snapshot "$base_snapshot"`。重排实验在对应命令增加 `--reranker "$minilm_dir"` 并使用表中重排阈值。目录需要固定版本的 ARM64 ONNX 文件和分词器，评估环境需要本地的 `onnxruntime==1.26.0`。评估脚本只读取仓库合成夹具及显式选择的本地资产。 [BGE-base 固定版本](https://huggingface.co/BAAI/bge-base-zh-v1.5/tree/f03589ceff5aac7111bd60cfc7d497ca17ecac65) · [MiniLM 固定版本](https://huggingface.co/cross-encoder/mmarco-mMiniLMv2-L12-H384-v1/tree/1427fd652930e4ba29e8149678df786c240d8825)
