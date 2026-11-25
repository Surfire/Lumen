# 在 Lumen 运行本地 Raycast 扩展

Lumen 宿主可打开你指定的本地 Raycast 扩展源码目录，列出其中的命令，并运行满足下表的 `no-view` 命令。自写的 MIT 示例 [Lumen Search Notes](examples/search-notes) 可显示宿主状态、格式化搜索笔记，以及生成可复制的 Markdown 链接。

| 接口 | 当前范围 |
| --- | --- |
| `package.json` | 要求 `name`、`title`、`description`、含 `macOS` 的 `platforms`、`commands` 和唯一运行时依赖声明 `@raycast/api`。允许版本及常用展示字段，识别并忽略 `scripts`、`devDependencies` 和图标路径。其他未识别的字段会使清单校验失败。 |
| 命令 | 仅接受启用的前台 `no-view` 定义，入口为 `src/<command-name>.js`。命令和包名称为最长 64 字节的小写 ASCII 字母、数字和连字符，首尾为字母或数字。已识别的 `view`、`menu-bar`、后台刷新及命令级偏好显示拒绝原因。 |
| 启动参数 | 0 至 3 个必填 `text` 参数，参数名称为 ASCII JavaScript 标识符。每项提交 1 至 1,024 字节的 UTF-8 文本。 |
| 源码 | 从 `@raycast/api` 导入 `showHUD` 或 `Clipboard`。默认导出的 `async function Command()` 或 `Command(props)` 只接受一条 `await showHUD(expression)` 或 `await Clipboard.copy(expression)`。注释、模板字面量、额外语句和 API 选项超出此语法。 |
| 文本格式化 | 最多拼接 16 个双引号 JSON 字符串或已声明的 `props.arguments.<name>`。每项可链式使用最多 8 次 `.trim()` 或 `.replaceAll("原文字", "替换文字")`。替换参数须为字面量，搜索文本须非空，替换文本不支持 `$` 记号。中间文本和输出最多 4,096 字节。 |
| 输出 | `showHUD` 返回纯文本消息。`Clipboard.copy` 只接受文本，返回待确认复制的纯文本。Lumen 面板在用户点击「复制到剪贴板」时才写入系统剪贴板。 |

扩展清单定义命令模式与源码路径，Raycast 将命令参数作为顶层 `arguments` 属性传入。Lumen 使用相同的源码目录、清单和参数形状，将文本交还调用方。Raycast 的 `Clipboard.copy` 自身负责写入剪贴板。Lumen 将这一步交给使用者确认，并只支持字符串形式。官方参考 [Manifest](https://developers.raycast.com/information/manifest) · [Arguments](https://developers.raycast.com/information/lifecycle/arguments) · [HUD](https://developers.raycast.com/api-reference/feedback/hud) · [Clipboard](https://developers.raycast.com/api-reference/clipboard#clipboard.copy)。

适用范围为本地源码包的 `no-view` 子集。剪贴板读取、清空、粘贴、文件复制和 `concealed` 等复制选项无扩展 API 支持。React 视图、TypeScript/JSX、Node 模块、窗口控制、偏好、存储、网络、系统命令、Raycast Script Commands、`.rayext` 和 Store 下载安装同样超出范围。Raycast 的构建、归档和安装流程见[官方 CLI 文档](https://developers.raycast.com/information/developer-tools/cli)及[开发指南](https://developers.raycast.com/basics/create-your-first-extension)。Script Commands 另见 [Raycast 用户手册](https://manual.raycast.com/script-commands)。

## 从 Lumen 界面运行

在接入扩展面板的 Lumen 构建中，从菜单或设置打开「Raycast 扩展」，点击「选择本地扩展包…」，选择 [Lumen Search Notes](examples/search-notes) 源码目录。选择 **Show Search Notes Status** 并点击「运行命令」，面板会显示扩展返回的文字。**Format Search Note** 会先要求填写 Topic 和 Note。选中标为「不支持」的命令可查看宿主给出的原因。

选择 **Copy Markdown Link** 并填写 Link title 和 URL。命令会去掉首尾空白，转义标题中的方括号和反斜杠，并对 URL 中的空格等字符做百分号编码。运行后先核对「复制预览」，再点击「复制到剪贴板」。命令不会访问或打开 URL。Markdown 链接语法见 [CommonMark](https://spec.commonmark.org/0.31.2/#links)。

面板沿用 Lumen 的简体中文、英语和跟随系统设置。命令标题、参数名和具体诊断保留原文。打开面板时不会扫描或运行扩展。用户选择包时才读取清单，点击运行时才执行所选命令。包在列出后有变更或无法验证时，面板清空旧命令，提示用户刷新并重新选择。

## 命令行示例

在仓库根目录运行。Cargo 使用现有 Rust 依赖和锁文件。

```sh
cargo run --locked --manifest-path extensions/Cargo.toml -- \
  --package extensions/examples/search-notes list

cargo run --locked --manifest-path extensions/Cargo.toml -- \
  --package extensions/examples/search-notes run show-ready

cargo run --locked --manifest-path extensions/Cargo.toml -- \
  --package extensions/examples/search-notes run format-note \
  --arg 'topic=索引' --arg 'message=只包含本地文件'

cargo run --locked --manifest-path extensions/Cargo.toml -- \
  --package extensions/examples/search-notes run copy-markdown-link \
  --arg 'title= 索引 [v2] ' --arg 'url= https://example.test/本地 文件(v2) '
```

`format-note` 输出 `{"hud":"[索引] 只包含本地文件"}`。`copy-markdown-link` 以 `{"clipboard":{"text":"…"}}` 返回预览，CLI 本身不写剪贴板。一般用法是 `lumen-extensions --package <目录> list` 或 `lumen-extensions --package <目录> run <命令> [--arg <名称>=<值>]`。每次明确指定一个目录，无安装数据库。成功时 stdout 为一行 JSON。命令失败时退出非零，stderr 给出原因。清单或包级校验失败时整个调用失败。已识别的命令级限制或源码校验失败在列表中以 `unsupported_reason` 返回，其它有效命令仍可运行。

宿主只打开显式选中的包里的 `package.json` 和可用模式声明的固定入口。文件必须是小型 UTF-8 普通文件（清单最多 64 KiB、单条命令最多 16 KiB、每包最多 64 条命令）。固定入口相对已打开的目录文件描述符读取，拒绝包内符号链接和多链接文件。macOS 要求包目录及其所有祖先都是真实路径，并在读取期间禁用 APFS 占位文件物化。Lumen 将命令源码解析成纯文本拼接程序。执行时只使用已编译的内存数据和传入参数，扩展没有 Node、shell、子进程、网络、文件系统或索引访问能力。依赖名仅用于校验，不进行 npm 安装或执行包脚本。

## 接入原生启动器

将 `extensions/LumenExtensionPanel.swift` 加入主应用的 Swift 编译输入。AppKit 调用方可从菜单或设置按钮响应中创建 `NSHostingView(rootView: LumenExtensionPanel())` 并放入原生面板。SwiftUI 调用方可从按钮呈现 `.sheet { LumenExtensionPanel() }`。面板自行读取现有 `language` 偏好，建议面板内容区至少为 580 × 360 点。

以发布模式构建辅助进程，将它复制到 `Lumen.app/Contents/Resources/lumen-extensions`，并在签名外层应用之前对其签名。

```sh
cargo build --locked --release --manifest-path extensions/Cargo.toml --target-dir target/extension-host
install -m 755 target/extension-host/release/lumen-extensions "$APP/Contents/Resources/lumen-extensions"
codesign --force --sign - "$APP/Contents/Resources/lumen-extensions"
```

面板使用 `Process` 参数数组运行 bundle 中的辅助进程，分别读取 stdout JSON 和 stderr。macOS 上，`list` 返回 `snapshot` 字段，使用系统 SHA-256 标识包目录身份、清单字节和实际读取的命令源码。面板在每次 `run` 时传入 `--expect-snapshot <值>`。宿主在即将运行的同一个 `Extension` 实例中验证标识。校验失败时退出码为 3，要求重新读取命令。直接在 CLI 输入 `run` 可单次显式执行，省略快照校验。

## 接入 Rust

Rust 主程序添加路径依赖 `lumen-extensions = { path = "extensions" }` 并更新主锁文件。

```rust
use lumen_extensions::{Extension, RunOutput};
use std::{collections::BTreeMap, path::Path};

let extension = Extension::open(Path::new(package_directory))?;
let catalog = extension.info();
// 列出 catalog.commands，只有 unsupported_reason 为 None 时允许执行。
match extension.run("show-ready", &BTreeMap::new())? {
    RunOutput::Hud { hud } => show_message(hud),
    RunOutput::Clipboard { clipboard } => preview_copy(clipboard.text),
}
```

`Extension::open(&Path)` 在该调用中读取并校验包。GUI 可在后台线程执行打开操作，通过 `info() -> &ExtensionInfo` 读取 `name`、`title`、`description`、`version` 和按清单排序的 `commands`，用包名加命令名构造搜索项标识。每条命令含标题、描述、可选副标题、关键词、模式、参数和可选的 `unsupported_reason`。参数描述含 `name`、`placeholder`、类型（JSON 字段为 `type`）与 `required`。用户选择命令后，将表单数据作为 `BTreeMap<String, String>` 交给同一个 `Extension` 实例的 `run`。目录内容更新时重新打开，已加载实例始终使用当时校验过的程序。

## 验证

```sh
cargo fmt --manifest-path extensions/Cargo.toml --check
cargo clippy --offline --locked --manifest-path extensions/Cargo.toml --all-targets -- -D warnings
cargo test --offline --locked --manifest-path extensions/Cargo.toml
extensions/tests/smoke-panel.sh
```

Rust 测试经独立 CLI 验证三个自写示例，并覆盖不支持的 API、链接、参数和大小限制，以及源码和包身份变更。Swift 无窗口测试在临时 app bundle 中使用与面板相同的状态模型和真实宿主，验证中文 HUD、Markdown 复制预览及确认后交付给复制函数。该测试使用合成写入函数。前台交互、系统剪贴板写入、原版 Raycast 和第三方扩展未经本轮实机验证。
