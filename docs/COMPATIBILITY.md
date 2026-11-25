# 兼容性、实现来源与许可证

本文区分**目标、可发现、可执行、已验收**。无探测结果时写“未知”；README/测试记录才是某个构建实际支持项的依据。

## Raycast：两个不同方向，逐级声明

| 等级 | 从哪里到哪里 | 验收方法 |
|---|---|---|
| R0 调用 Lumen | 用户在原版 Raycast 内，使用调用 Lumen 的独立 Script Command/扩展 | 原版 Raycast 制造查询并展示返回的真实文件；只有脚本样板不算 GUI 联调 |
| R1 发现扩展 | Lumen 读取已安装扩展的 manifest 或受支持脚本头 | 离线解析、校验命令名/平台/参数/模式、列出不支持的字段；发现≠执行 |
| R2 运行限定命令 | 在 Lumen 选中一个已验证的命令并实际取得输出 | 按能力清单验证；无权或不能隔离的不执行；超时、取消、非零退出可见。脚本命令不等于 React 扩展 |
| R3 交互式扩展 | Lumen 自有宿主支持列明的 Raycast UI/API 子集 | 自写/适配 List、Detail、Action、Form 等逐项验收；至少一个非特制、明确授权的真实扩展能在 Lumen 完成工作 |
| R4 广泛生态 | 真实、固定版本、许可明确的扩展兼容矩阵 | 声明具体通过哪些扩展，Node/React 依赖、网络、Keychain、剪贴板等能力都有明确的允许/拒绝；不承诺整店通用 |

Raycast 把命令、模式与平台定义在[扩展 manifest](https://developers.raycast.com/information/manifest)，交互式视图另有 [List API](https://developers.raycast.com/api-reference/user-interface/list)。包能被识别不代表运行时 ABI/API 一致。不安装不明 npm 包、不运行 postinstall、不从第三方仓库拉取脚本后自动执行。任何可执行扩展都按来源、版本和所需能力单独授权；不以“这是个搜索工具”推导它可以任意 shell 执行或读取全盘索引。尚未具备可靠隔离时仅开放清楚界定并经用户信任的本地命令子集，否则保持只读发现。无法保障的能力拒绝并显示原因；加载扩展失败不阻塞文件搜索。

## macOS、网盘和文件格式

- 优先 Apple Silicon macOS；以实际发布产物的部署目标为准。不因 Rust 可跨平台就宣称 Windows/Linux 已支持。
- **OneDrive / iCloud / 其他 File Provider**：按系统提供的本地可见元数据索引。已枚举名称、目录覆盖缺口和正文读取状态须能区分。不能替代提供商远程目录 API，不保证看见从未列到本机的条目。陌生提供商按保守规则处理。不要用 `st_blocks == 0`、非零文件大小或仅路径前缀证明“已下载”。
- **普通文件协议**：文件名可与格式无关；“搜到 PDF 名字”与“读了可搜索的 PDF 正文”不是一回事。文本层 PDF 只标真实页，DOCX 只在提取段落和表格成功时标相应位置，不虚构页码。首次迭代只支持其中一些格式也应逐一列明。OCR、图像向量、复杂附件解包需独立设计。
- **语言**：数据存储保留原文，搜索键独立规范化；UI 使用翻译键与回退语言。中文界面、中文文件名及拼音、中文全文分词、中文语义分别验证，不把其中一个代表其余三个。

## MIT 发布清单

Lumen 的新代码采用 MIT。Tinycast 仅供研究产品交互（该参考项目仓库声明 AGPL-3.0-or-later）；Oil Find 和 DigUp 仅供研究搜索方法（参考仓库声明 MIT）；既有 Luminator Index 亦仅供参考。**即使许可允许复用，本项目按用户要求也不复制上述项目代码、映射表、图标、UI 资源、测试语料、配置或二进制。** 名称引用用于说明来源，不暗示对方背书。

比较依据：[Tinycast](https://github.com/abue-ammar/tinycast)、[Oil Find](https://github.com/oil-oil/oil-find)、[DigUp](https://github.com/ARahim3/DigUp)。设计可通过 Apple 公开 API 与自建 Rust 模块独立实现。Rust crates、系统库、字体、翻译、模型权重和每个扩展分别看授权；MIT 不会自动重新许可第四方材料。不要把 Apple 系统库、Raycast 专有运行时/商店内容、或未审查许可的模型嵌入发布包。

**发布前逐项检查：** 跟踪文件清单与依赖锁文件；适用许可、NOTICE 与模型分发要求；无本地姓名路径/邮箱样本、云盘文件清单/数据库、凭证、签名材料或构建缓存。只公布合成样本与匿名化指标。目录有 README 不等于已构建，生成 .app 不等于已签名公证，生成扩展不等于已上架 Raycast Store。
