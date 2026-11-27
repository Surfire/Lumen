<p align="center">
  <img src="assets/readme/lumen-hero-zh.png" width="100%" alt="Lumen · 鹿鸣：macOS 原生极速检索、PDF 匹配页高亮直达与本地语义搜索">
</p>

<p align="center">
  <img src="assets/readme/lumen-logo.png" width="68" alt="Lumen 鹿鸣 Logo">
</p>

<h1 align="center">Lumen · 鹿鸣</h1>

<p align="center">
  <strong>一个快捷键，秒找全盘文件、打开应用、直达系统设置与文档答案。</strong><br>
  Rust 零倒排 SoA + AArch64 NEON 原生检索引擎，搭配 SwiftUI / AppKit 极简交互。<br>
  支持全盘文件名与拼音毫秒查找、PDF 匹配页视觉直达、EmbeddingGemma 本地语义搜索，以及不唤醒云端占位文件的安全边界。
</p>

<p align="center">
  <a href="#界面预览">界面预览</a> ·
  <a href="#为什么选择-lumen">核心能力</a> ·
  <a href="#同类工具对比">竞品对比</a> ·
  <a href="#实测性能与内存表现">性能实测</a> ·
  <a href="#快速上手与安装">快速上手</a> ·
  <a href="README.en.md">English</a>
</p>

<p align="center">
  <code>v0.5.1</code> · <code>Apple Silicon</code> · <code>macOS 14+</code> · <code>Rust + AppKit / SwiftUI</code> · <a href="LICENSE"><code>MIT License</code></a>
</p>

---

| 试着输入 | 你会看到什么 |
| :--- | :--- |
| `年报 复盘 pdf` | 同框多词匹配并按真实扩展名过滤；支持双引号精确短语搜索 |
| `luming` / `lm` | 全拼或首字母直接定位中文文件名「鹿鸣」 |
| `蓝牙` / `25 km in mi` | 无需等待文件索引，直接跳转系统设置或本地实时计算/单位换算 |
| `tr:en 会议改期了` | 同一输入框流式翻译，回车一键复制结果（支持本机 oMLX 与 OpenAI 兼容服务） |
| `qa 如何整理周报结构` | 本机提问大模型，按 `Esc` 立即取消，不联网抓取、不附带本地文件 |
| `img 帆船` | 基于本地视觉模型按画面语义搜图，全过程零数据上传 |

---

## 界面预览

### 搜索列表与「视觉优先」文档预览（深浅色自适应）

> 选中 PDF 命中项按 **`空格`** 或 **`⌘Y`** 预览：内联窗格先展示已定位页码与半透明琥珀色高亮的页面视图，再在其下方列出原文上下文；呼出独立 Quick Look 悬浮窗则会按 PDF CropBox/旋转角或图片像素/EXIF 比例自适应缩放窗口尺寸。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/readme/search-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/readme/search-light.png">
    <img src="assets/readme/search-light.png" width="90%" alt="Lumen 搜索与内联 PDF 匹配页高亮预览界面">
  </picture>
</p>

### 原生 macOS 设置与触感快捷键体验

> 使用原生 AppKit/SwiftUI 开关组件、实体按键帽热键录制、独立目录与排除优先级规则，以及离线模型状态灯与单文件无唤醒诊断。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/readme/settings-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="assets/readme/settings-light.png">
    <img src="assets/readme/settings-light.png" width="90%" alt="Lumen 原生 macOS 设置界面">
  </picture>
</p>

---

## 为什么选择 Lumen

- **全盘文件名约 1 ms 极速响应，百万级常驻仅 ~145 MiB**
  在单一轻量核心中采用紧凑结构体数组（SoA）与 **AArch64 NEON SIMD** 并行扫描架构，放弃冗重的内存倒排表，且文本检索通道不再重复持有名称索引。实测在 **166.7 万条真实磁盘文件** 下，全盘名称、拼音与路径热查询稳定在 **0.79–1.75 ms**，常驻内存约 **144.7 MiB**。
- **语义与全文命中直达页内，不再只看几行冷冰冰的摘录**
  对 TXT、Markdown、DOCX（正文与表格）及原生 PDF 文本层建立按需本地索引；PDF 命中结果时直接跳转到对应的页码并在原页面上用琥珀色高亮匹配位置。内联预览默认 **先看画面、再看上下文**，不打断当前搜索会话焦点。
- **自适应比例的原生 Quick Look 悬浮窗**
  浏览结果时按 **`空格`**（打字时空格保持正常输入）或按 **`⌘Y`** 打开独立预览窗：自动识别 PDF CropBox 与页面旋转角度、图片真实像素与 EXIF 方向、文档/视频/音频等扩展类型比例，避免所有文件千篇一律挤进固定方块。
- **严格克制的本地 EmbeddingGemma 语义 & 搜图**
  选配本机 EmbeddingGemma 模型后，可在完全离线环境下按自然语言找文档与图片（`img ...`，支持 PNG/JPEG 及离线图像检索流水线）。语义排序经过相关性校准：无关噪音词返回 0 条虚假相似项，高相关文档再附带原页跳转；纯文件名检索完全不依赖模型。
- **默认零误触发云端下载的网盘保护边界**
  底层检索、预览和诊断统一强制启用 `IOPOL_VFS_MATERIALIZE_DATALESS_FILES_OFF`、`SF_DATALESS` 检查与 `O_NOFOLLOW_ANY`。已识别的 iCloud Drive、OneDrive 与 File Provider 目录仅记录系统可见元数据，**绝不因为扫描或预览偷偷下载只存在云端的文件**。
- **一把称手的日常 macOS 效率中枢**
  同一个窗口整合：应用与系统设置模糊启动、常用项目固定（空查询即可见）、数学计算与单位换算、快捷链接（`g` 默认开启；`gh`/`wiki`/`map` 及自定义 HTTPS 别名按需开启）、需主动开启的私密剪贴板历史、本地脚本与 Apple 快捷指令、基于 macOS 辅助功能的窗口排版，以及 `tr` / `qa` 流式问答与翻译。

---

## 同类工具对比

| 维度 | **Lumen · 鹿鸣** | **macOS Spotlight** | **Raycast / Alfred** | **Oil Find** | **DigUp** |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **定位** | 全盘秒搜 + 文档/语义直达 + 全能启动器 | 系统内建搜索 | 扩展生态驱动的启动器 | 高性能专用文件查找器 | 本地多模态内容检索引擎 |
| **文件名搜索引擎** | 自研 Rust 零倒排 SoA + NEON 并行扫描 | 系统 `mds` / `mdimporter` | 依赖 macOS Spotlight（`mdfind`） | 自研 C + NEON 扫描与筛选 | 侧重内容切片向量检索，非全盘文件名启动器 |
| **百万级常驻内存** | **~145 MiB**（实测 166.7 万真实文件） | 系统分布式后台常驻（不可控） | 启动器进程轻量，但依赖系统索引驻留 | 极低内存文件名常驻 | 随本地模型与向量索引规模动态变化 |
| **文档正文与本地语义** | 本地 FTS + **EmbeddingGemma** 离线检索（免费开源） | 仅关键词/元数据，无本地大模型语义召回 | 依赖 Spotlight 或插件/云端 AI | 基础版搜文件名/外置盘；文档/图像搜索需付费 Pro | 免费开源 **EmbeddingGemma 2** 多模态深搜 |
| **PDF 命中页定位与高亮** | 内联与独立预览窗 **直达命中页 + 页内高亮** | Quick Look 仅打开文件或基础查找 | 按扩展/Quick Look 方式预览 | 侧重定位文件路径与基础预览 | 展示匹配片段与定位信息 |
| **拼音 / 首字母检索** | 原生内建全拼与首字母缩写（`luming`/`lm`） | 有限支持，偶发失效 | 需额外插件或自定义脚本 | 原生支持拼音/多模式匹配 | — |
| **启动器扩展工作流** | 应用、设置、计算、剪贴板、窗口、脚本/快捷指令、`tr`/`qa` | 应用、计算与系统网页建议 | **强项**：丰富扩展生态与热键命令 | 无应用启动、剪贴板或窗口管理 | 专注文档与媒体检索，非启动器 |
| **网盘零误下载保证** | 线程级 `IOPOL` + `SF_DATALESS` 零唤醒隔离 | 视云盘 File Provider 与系统规则而定 | 依赖系统索引或插件实现 | 检查占位标识，尊重系统云文件状态 | 面向本机已选媒体目录 |
| **开源与授权** | **MIT 开源免费** | 闭源系统组件 | 核心免费（部分高级功能订阅制） | 文件名/外置盘 MIT 开源；Pro 功能闭源付费 | **开源免费** |

---

## 实测性能与内存表现

### 1. 166.7 万真实磁盘项目实测（Apple Silicon，热态 `lumen serve`）

在包含 **1,667,692 条真实本机文件/目录**、**2,370 份正文档** 与 **43,690 条 Gemma 向量** 的真实工作库上验证（单名称索引驻留 + 双通道隔离）：

| 查询场景 | 实测耗时 / 占用 | 说明 |
| :--- | ---: | :--- |
| 拼音首字母名称查询（`lm`） | **0.79 ms** | `mode=name` 热态返回 Top 60 |
| 中文双字名称查询（`临床` / `项目` / `工作` / `报告`） | **0.85–0.93 ms** | 并行 NEON 零倒排扫描 |
| 英文名称查询（`readme`） | **1.10 ms** | `mode=name` 热态 |
| 高频词 / 单字回退（`方案` / `方`） | **1.54–1.61 ms** | 166.7 万条全盘扫描无索引退化 |
| 不存在关键词名称排空（`哈基米`） | **1.75 ms** | 快速排空，不再卡顿 1–2 秒 |
| 常驻检索服务进程内存（`lumen serve` RSS） | **144.7 MiB** | 仅 `nameLane` 持有单一 `NameFast` 实例 |
| 正文全文热查询（`方案` / 不存在 FTS 词 `哈基米`） | **46.61 ms** / **0.16 ms** | `mode=text` + FTS5 前缀索引 |
| 本地 EmbeddingGemma 语义召回（14 组对照） | **~18–25 ms** | 7/7 相关查询稳定返回 11–12 条；7/7 无关词返回 **0 条噪音** |

### 2. 一百万合成文件微基准（Apple M5 Max）

在 Apple M5 Max 上首次扫描 1,000,000 个合成文件耗时 **45,503.66 ms**，预热后 `lumen serve` 内存为 **140,880 KiB（137.58 MiB）**（更新可见性检查后为 **146,960 KiB / 143.52 MiB**），4,000 次热查询均在前 20 位命中：

| 热查询类别 | p50（ms） | p95（ms） | p99（ms） |
| :--- | ---: | ---: | ---: |
| 拉丁名称 | 0.253 | 0.328 | 0.357 |
| 中文名称 | 0.495 | 1.195 | 1.368 |
| 拼音 | 0.477 | 0.961 | 1.079 |
| 多词 | 0.264 | 0.342 | 0.402 |

> 注：以上均测量核心引擎 / 常驻 CLI 的热态检索与驻留内存；图形界面整条链路延迟另受 SwiftUI 列表渲染与防抖调度影响，详细信息与十万级并发数据见 [v0.4 基线](benchmarks/v0.4-baseline.md) 与 [基准协议](docs/BENCHMARK.md)。

---

## 常用按键与命令速查

| 输入或按键 | 动作 |
| :--- | :--- |
| **`⌃⇧Space`**（可自定义） | 从任何应用上方无焦点抢占呼出 / 隐藏 Lumen |
| **`?`** | 浏览全部内置命令，方向键选择，回车填入搜索框 |
| **`tr` / `qa` / `img`** | 同输入框翻译、本机提问大模型、以文搜图 |
| **`g`** / `gh` / `wiki` / `map` | 网页快捷搜索（可在「设置 → 快捷链接」按需开启或添加） |
| **`↩` / `⌘↩` / `⌘K`** | 打开选中项、在 Finder 中显示、呼出当前项操作菜单 |
| **`空格` / `⌘Y` / `Esc`** | 浏览结果时 `空格` 快速预览，打字时正常输入；`⌘Y` 切换预览；`Esc` 优先关闭预览再收起窗口 |
| **`⇧⌘C` / `⌥⌘C`** | 复制文件名或完整路径 |
| **`⌘,`** | 打开原生设置 |

- 翻译 / 问答模型配置详见：[提供商配置](docs/TRANSLATION.md)
- 离线语义与视觉模型配置详见：[离线语义](docs/offline-gemma.md) · [模型、投影器和大小限制](docs/offline-image-search.md)

---

## 快速上手与安装

### 从源码构建

需要 **Apple Silicon Mac**、**macOS 14+**、Xcode 命令行工具与 Rust 工具链：

```sh
scripts/build-app.sh
open target/Lumen.app
```

上述命令生成临时签名（ad-hoc）开发版；日常安装推荐使用命名本地签名身份以保留磁盘权限，并在升级时使用 `install-app.py` 原子替换：

```sh
LUMEN_SIGN_IDENTITY="Lumen Local Code Signing" scripts/build-app.sh
python3 scripts/install-app.py install target/Lumen.app
open -a "$HOME/Applications/Lumen.app"
```

更多细节、回滚与证书迁移见：[本机签名、安装和回滚](docs/UPGRADING.md)。

### 签名发布与 Homebrew

- **应用内签名更新**：对于使用正式发布证书签名并安装在可写「应用程序」目录中的副本，可在 **「设置 → 高级与诊断 → 检查更新」** 手动触发更新；Lumen 会校验清单签名、ZIP 校验和与应用代码签名后再原位替换并备份旧版。
- **Homebrew**：通过 Homebrew tap 安装的用户可直接执行 `brew upgrade --cask lumen`。普通卸载保留索引与配置；`--zap` 会一并清理偏好设置、脚本与剪贴板历史。

---

## 开发、架构与完整回归

[架构文档](docs/ARCHITECTURE.md) · [兼容范围](docs/COMPATIBILITY.md) · [版本变更](CHANGELOG.md) · [第三方依赖](THIRD_PARTY.md)

<details>
<summary>构建、代码检查与全套自动化验收命令</summary>

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
scripts/build-app.sh
LUMEN_SMOKE=1 scripts/build-app.sh
python3 scripts/smoke-app.py
python3 scripts/smoke-launcher.py
python3 scripts/smoke-relaunch.py target/Lumen.app
python3 scripts/smoke-translation.py
python3 scripts/smoke-install-app.py
python3 scripts/smoke-updater.py
```

验收默认采用可复现合成资料；AppKit 焦点与 FSEvents 测试依赖 macOS 桌面会话环境。

</details>

源码采用 [MIT License](LICENSE)。产品与工程设计在独立实现中吸取并致敬了 Tinycast、Oil Find、DigUp 与 Luminator Index 的优秀理念。
