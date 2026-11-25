# EmbeddingGemma 2 的本机文本检索

Gemma 2 是默认语义模型。名称和正文检索继续走原有本地索引。语义读取已明确启用正文索引的范围，只返回相关原文片段。

## 安装资源

在 Apple Silicon macOS 准备官方文本 GGUF 和 llama.cpp 压缩档案。安装器只读取显式指定的本机文件，校验档案、模型及使用的二进制成员，并将资源放在当前用户独立目录。默认目录为 `~/Library/Application Support/Lumen/Gemma2`。它要求新目录，现有资源可以继续使用。`--destination` 对应 CLI 的 `--gemma-home`。不需要图像或音频投影权重。

```sh
python3 scripts/install-local-gemma.py --model "$gguf" --archive "$runtime_archive"
```

固定散列见 [`scripts/gemma-assets.json`](../scripts/gemma-assets.json)。模型为 Apache 2.0，llama.cpp 为 MIT。安装器保留运行时的 LICENSE。 [Google 模型卡](https://huggingface.co/google/embeddinggemma-2) · [固定文本 GGUF](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/6ea3e3a309d12a4779cfda98b8c19800d2d5da71/embeddinggemma-2-Q8_0.gguf) · [llama.cpp b11457](https://github.com/ggml-org/llama.cpp/releases/tag/b11457)

## Launcher 协议

- `model-status --gemma --verify` 验证运行时、权重和离线双向跨语言合成检索。`available` 为已通过所请求级别的检查，`verified` 仅在实际运行成功后为 `true`。作为单独的资源检查，它的 `coverage` 为 `null`。
- `embed --gemma --max 32` 对已有正文索引分批回填。返回 `new_embeddings`、`skipped_chunks`、`has_more`。使用相同库重试会续跑。结果绑定到索引段落的单调 ID，替换文件、关闭正文或收窄范围后，已失效的输入不能继续写入。
- `gemma-status --verify` 返回 `backend`、`model_id`、`available`、`verified`、`ready`、`diagnostic` 和 `coverage`。覆盖对象包含 `documents_enabled`、`embedded_chunks`、`skipped_chunks`、`pending`、`limited` 和 `chunk_limit`。`ready` 要求真实验证通过且至少存在一个属于当前模型及已核验文档的向量。`pending` 表示仍有段落待回填，`limited` 表示达到存储上限且仍有待回填段落。这两个状态可以和 `ready` 同时为真，此时继续搜索已有向量。可通过 `status` 内的 `gemma` 对象读取覆盖而无需启动运行时。
- `semantic-serve` 在 stdin 接受 JSONL，每行与 `serve` 一样使用 `id`、`query`、可选 `limit`。返回 `{id,hits}` 或 `{id,error}`。连接复用一次验证后的 Gemma 子进程，退出或关闭 stdin 时自动回收。输入帧含换行最多 16 KiB，超长或未终止帧结束该连接。正常查询去除首尾空白后最多 512 个 UTF-8 字节。建议独立于名称／全文会话，迟到结果仍按 launcher 当前查询和范围核对。
- `query --mode semantic` 默认使用已就绪的 Gemma。显式 `--gemma` 可检查已回填的部分库。`--bge` 保留原语义配置和同库回退，Gemma 的增量构建不会改变现有 BGE 向量槽。

运行时只接受父进程经私有 Unix socket 发来的认证请求。模型使用官方检索查询前缀，段落采用 `title: none`，因为索引没有经过验证的原文标题字段。向量的身份包含模型散列、运行时、前缀版本和归一方案。

## 合成验收

```sh
LUMEN_GEMMA_TEST_HOME="$isolated_gemma_dir" cargo test --locked --test cli \
  real_gemma_cli_preserves_legacy_bge_and_replaces_only_changed_document_vectors -- --ignored
```

该测试在临时库中加载真实 Gemma 权重，核对两批回填、768 维向量、中英互搜、原文片段、同库 BGE 协议回退和文档替换失效。
