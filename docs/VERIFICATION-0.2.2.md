# Lumen 0.2.2 核验

- 普通菜单栏启动探针、签名和包资源冒烟，以及九组隔离原生 GUI 检查。合成文件覆盖中、英文搜索和两套本地 BGE。
- 单一搜索框并行查名称和正文：强名称优先、正文不会被大量弱路径结果淹没。语义命中异步追加、按路径去重，并保留原选中项。输入及索引更新期间未观察到额外窗口缩放；短暂显示旧行时不能触发旧查询动作。
- 回车打开；⌘↩ 显示所选文件或云盘条目。测试覆盖原生键盘事件、macOS Finder 调用入口、文件变化与并发索引刷新下的二次校验、云盘占位文件不读取正文。测试没有在用户桌面实际激活 Finder，也未发送全局按键。
- 本版本保持 BGE 语义；EmbeddingGemma 2 是后续模型集成，不包含在本包。

重跑：`scripts/build-app.sh --offline`、`python3 scripts/smoke-app.py`、`python3 scripts/smoke-launcher.py --watch-engine target/release/lumen --real-bge`。
