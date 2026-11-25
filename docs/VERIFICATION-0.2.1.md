# Lumen 0.2.1 核验

- 签名应用包通过 `codesign --verify --deep --strict`。资源冒烟通过，覆盖原生 PDF 提取、扩展宿主和语义资源。
- Rust 引擎与 CLI 共 31 项通过（包括 macOS FSEvents），扩展宿主 10 项通过；Clippy 和格式检查通过。
- 普通菜单栏应用启动探针通过：观察到未激活、未创建搜索窗。9 组隔离原生 GUI 测试通过，包括后台扫描期间搜索窗保持收起、完成后不弹出、菜单栏入口、进度与无依据不显示剩余时间、快捷键录制和注册失败回退、中文与英文、两个真实本地 BGE 配置。后两项 BGE 检查使用合成文档。
- 快捷键覆盖 Carbon 注册与进程内回调。普通启动探针与后台生命周期分别验证，未在他人正在使用的桌面发送全局按键；没有声称已验证实际跨应用按键或另一个应用在整个扫描期间持续收到输入。
- 同一台 Mac、每组 10 万合成文件、前后 release 各三轮交替、每轮从空数据库起步且未清空系统缓存。中英混合文件名首建中位数 4.394 → 1.939 秒；纯 ASCII 3.582 → 1.132 秒。仅是该测试的名称索引，不代表全盘和全文性能，也不作为对竞品的运行时比较。

重跑：`scripts/build-app.sh --offline`、`python3 scripts/smoke-app.py`、`python3 scripts/smoke-launcher.py --watch-engine target/release/lumen --real-bge`。运行包含 FSEvents 的测试需要能启动原生文件事件流的本地会话。
