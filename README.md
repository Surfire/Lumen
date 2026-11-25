# Lumen

Lumen 是独立开发的 macOS 本地搜索工具。Rust 负责扫描、索引与检索，AppKit 和 SwiftUI 提供原生菜单栏启动器。产品设计参考 Tinycast、Oil Find、DigUp 与早期 Luminator Index，未复制其源码或资源。

## 在 Mac 上构建

Apple Silicon、macOS 14 或更新版本、Xcode 命令行工具和 Rust。实际验证环境为 Apple Silicon macOS 27.0.1。构建不会安装到 Applications、替换 Spotlight、修改系统快捷键或注册登录项。

```sh
scripts/build-app.sh
open target/Lumen.app
```

启动后在菜单栏打开 Lumen，或使用默认快捷键 **Control + Shift + Space**；可在设置里修改或关闭。首次明确点击「建立索引」后，搜索窗会收起，索引留在后台；在菜单栏可看阶段、已扫描数量和耗时，有同范围样本时才显示估算剩余时间。可设置单修饰键组合（含 Command + 反引号）；该组合也是系统的窗口切换键，若被占用会保留原快捷键，菜单栏仍可打开搜索。白名单留空时使用启动盘可访问的范围，不必逐个选择文件夹；跳过系统、隐私、缓存、隐藏目录及默认范围外的卷。黑名单优先。支持简体中文、英语及随系统语言。

## 搜索和文件更新

- 同一个搜索框匹配文件名、路径、拼音和已索引的正文，不用选搜索模式。方向键选择，回车打开，⌘↩ 在 Finder 中显示所选项目，Esc 关闭。名称搜索不依赖模型。
- 开启正文后可查本地 TXT、Markdown、DOCX 主文档的段落与表格、PDF 原生文本层。没有 OCR 或 DOCX 页码。超限、加密或不支持的文档保留名称，不假报已读取。
- 名称与范围会随 macOS 文件变化更新。文件新增、改名、移除、正文变更与重启后的补偿已用合成目录测试。索引文件保存在用户本机；引擎不监听网络端口。
- 已识别的 OneDrive、iCloud 和 File Provider 仅录入系统可见的名称和路径；不会打开网盘文件做正文抽取，也不调用同步 API。系统未列出的条目不在可查范围。不能在未经过测试的提供商或未确认路径上保证同样覆盖。
- 可选语义索引按段落分批生成。满足输入条件且已有匹配语义索引时，后台补充最多三条相关原文，不替换已有的直接匹配。0.2.2 使用已校验的离线 BGE，不会自动下载或联网。模型不判断片段是否已经回答问题。安装、固定模型版本和误报评估见[离线语义候选](docs/offline-semantics.md)。

## Raycast 兼容

在菜单栏打开「扩展」，手动选择本地源代码目录。Lumen 能运行 [明确支持的 Raycast no-view 子集](extensions/README.md)，包含 `showHUD` 文本和受确认保护的 `Clipboard.copy` 文本。打开面板不会自动扫描或执行扩展。它不包含 Raycast Store、Node、任意 JavaScript、Script Commands、TypeScript/React 界面或全部 `@raycast/api`。

## 独立验证

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked                         # FSEvents 用例需要系统允许通知流
cargo test --locked --manifest-path extensions/Cargo.toml
scripts/build-app.sh
python3 scripts/smoke-app.py
python3 scripts/smoke-launcher.py
extensions/tests/smoke-panel.sh
```

验证使用合成文件。macOS 命令环境若阻止 AppKit 或 FSEvents，不能把相应测试失败、跳过或模拟结果算成真实系统验收。历史开发基线见 [0.1 合成实测](docs/BASELINE-0.1.md)，本版核验见 [0.2.2 验证](docs/VERIFICATION-0.2.2.md)，启动器历史验收见 [0.2.1 验证](docs/VERIFICATION-0.2.1.md)，上一版对照见 [0.2 验证](docs/VERIFICATION-0.2.md)，测量规则见 [基准协议](docs/BENCHMARK.md)。命令行或引擎级基准不能代替原生启动器的正确首帧，更不能概括竞品所有功能。

设计：[产品](docs/PRODUCT.md) · [架构](docs/ARCHITECTURE.md) · [兼容范围](docs/COMPATIBILITY.md) · [第三方依赖](THIRD_PARTY.md)。

Lumen 原创源码采用 [MIT](LICENSE)。第三方依赖各按自己的许可分发；不捆绑模型权重。
