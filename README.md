# Lumen

面向 macOS 的本地文件搜索启动器。Rust 管扫描、索引和检索；原生 macOS 窗口负责输入和展示。独立实现，不需要已安装 Tinycast、Luminator、Oil Find、DigUp 或 Raycast。界面可在简体中文、英语和系统语言间切换。

## 运行首版

需要 Apple Silicon、macOS 14+、Xcode 命令行工具和 Rust（构建使用 1.96）。

```sh
scripts/build-app.sh
open target/Lumen.app
```

构建的是本机临时签名的应用，不会安装到 Applications、不改 Spotlight、不注册登录项或全局快捷键。打开应用不会立刻扫描，点击「建索引」后才开始。**白名单留空，默认扫描启动盘内可读取的常规文件；不要求事先把每个目录手动加入。** 内置保护排除系统路径、隐私和缓存目录、隐藏文件、未明确指定的外接或网络挂载；不跟随符号链接。自定义黑名单优先于白名单，白名单、黑名单以及正文开关在重建索引后生效。

名称、路径、中文、全拼和首字母可以直接搜索。默认只存元数据；勾选正文后，额外写入本地 TXT、Markdown 和 PDF 文本层（不 OCR）。OneDrive、iCloud 和常见 File Provider 的可见名称和路径无需手动加根；遇到占位目录不下钻，不打开云盘文件的正文或预览，不调用同步 API。不保证能发现云端尚未提供给 Finder 的条目。

进入设置可启用正文索引和生成语义索引。选择简体中文或英语，点击「生成下一批语义索引」，再用「搜语义」查询。使用本机已有的 Apple [Natural Language 句向量](https://developer.apple.com/documentation/naturallanguage/nlembedding/sentenceembedding(for:))，不主动下载模型，不提交查询或文件到网络。未装相应语言模型时会报错。两种语言的向量不可混用；切换模型语言需要重新生成向量。常规名称和全文不依赖模型。

## CLI

将 SAMPLE 换成一个你明确愿意索引的测试目录。索引默认保存在用户本机的 Application Support/Lumen，文件为 0600；可用 `--db` 指向独立测试库。

```sh
lumen=target/Lumen.app/Contents/Resources/lumen
assets=target/Lumen.app/Contents/Resources

"$lumen" --db /tmp/lumen-sample.sqlite index --root "$HOME/Documents/SAMPLE" \
  --documents --pdf-helper "$assets/LumenPdfExtractor"
"$lumen" --db /tmp/lumen-sample.sqlite query slyb
"$lumen" --db /tmp/lumen-sample.sqlite query '合作分工' --mode text
"$lumen" --db /tmp/lumen-sample.sqlite embed --helper "$assets/LumenLocalEmbedding" --language zh
"$lumen" --db /tmp/lumen-sample.sqlite query '如何分配参与者的责任' \
  --mode semantic --helper "$assets/LumenLocalEmbedding" --language zh
"$lumen" --db /tmp/lumen-sample.sqlite status
```

`index` 不给 `--root` 或 `--allow` 时从启动盘根目录 `/` 开始；`--allow` / `--deny` 可多次使用。Rust 通过 Darwin `getattrlistbulk` 批量读取名称和属性，不适用时回退常规枚举。macOS 访问策略禁用自动物化；无法启用策略即停止索引。根据系统可见性记录跳过和读取异常数量。CLI 也支持 `serve` 持久 stdin/stdout JSON，供原生窗口使用，**不监听网络端口**。

## 当前边界

- 这是 **0.1 可体验底座**，不是已经达到可取代 Spotlight 的版本。尚无即时增量通知、全局键盘唤起、应用/命令工作流、Raycast 扩展宿主或 Store 安装兼容。改名或删除后需重建；重建会清空向量，按批重新生成。扩展不读取、不运行。
- 云盘只收录可枚举的本机元数据，包括已下载条目；为避免误读或触发下载，本版仍不处理任何已识别云盘路径的正文。没有实机已登录 OneDrive/iCloud 对照，现有试验用合成占位规则验证。
- 纯文本 ≤ 2 MiB；PDF ≤ 24 MiB、≤ 350 页、文本 ≤ 2 MiB。加密 PDF、扫描件、DOCX 不做正文处理。抽取器仅从 stdin 接收已获准读取的文件字节，不直接访问用户路径。全文结果显示原文片段，不承诺 PDF 页码跳转。
- 语义对每份正文开头 1,400 字做一个向量、顺序余弦检索，按需分批；不等于大片段向量索引或多语种语义评测。已有索引没有自动实时刷新。尚未验证屏幕渲染、中文 IME、真实全盘/云盘覆盖及热键闭环。

## 验证与设计

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
scripts/build-app.sh
python3 scripts/smoke-app.py
python3 scripts/benchmark.py --entries 100000
```

设计：[产品](docs/PRODUCT.md) · [架构](docs/ARCHITECTURE.md) · [兼容范围](docs/COMPATIBILITY.md) · [性能验收方法](docs/BENCHMARK.md) · [首版合成实测](docs/BASELINE-0.1.md)

MIT，见 [LICENSE](LICENSE)。Cargo 依赖由锁文件固定，各自保留原许可。系统框架和 NLEmbedding 由本机 macOS 提供，不再分发模型权重。
