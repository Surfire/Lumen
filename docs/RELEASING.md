# 发布与分发指南（Releasing Lumen）

Lumen 支持 **Path B（无付费苹果开发者账号的社区分发）** 与 **Path A（Apple Developer ID 签名 + 公证 + 应用内全自动自升级）** 两种发布模式，共用同一套 GitHub Actions 工作流（[`.github/workflows/release.yml`](../.github/workflows/release.yml)）与打包脚本（[`scripts/package-release.sh`](../scripts/package-release.sh)）。

---

## 1. Path B：无开发者账号直接发版（当前默认）

1. 更新 [`scripts/build-app.sh`](../scripts/build-app.sh) 中的 `CFBundleShortVersionString` 与 `CFBundleVersion`。
2. 推送版本标签（或手动在 Actions 运行 `Release` 工作流）：
   ```sh
   git tag v0.5.1
   git push origin v0.5.1
   ```
3. CI 在 `macos-15` Runner 上自动执行 Rust 测试、纯 Release 构建、`smoke-app.py`，并调用 `LUMEN_ALLOW_UNSIGNED=1 scripts/package-release.sh` 产出并上传以下附件：
   - `Lumen-macos-arm64.dmg`（拖拽安装镜像）
   - `Lumen-macos-arm64.zip`（Homebrew Cask / CLI 压缩包）
   - `lumen-update.json`（版本元数据清单，用于只读更新提醒）
   - `SHA256SUMS.txt`（全部产物的 SHA-256 校验列表）

### 种子用户首次安装说明（无公证构建）

拖拽 `Lumen.app` 到 `/Applications` 后，若系统提示“无法验证开发者/已损坏”，在终端执行一次：

```sh
xattr -dr com.apple.quarantine /Applications/Lumen.app
```

Path B 构建可每 24 小时检查更新并在新版发布时给出 **「打开下载页」** 提示，但处于安全策略考虑，**不会**执行无签名原位二进制替换。

---

## 2. Path A：升级为 Developer ID 签名 + 公证（零流程重写）

日后获得 Apple Developer ID Application 证书后，只需在 GitHub Repository Secrets 中配置以下密钥，`release.yml` 会自动切换至 Path A：

| Secret | 用途 |
| :--- | :--- |
| `APPLE_CERT_P12_BASE64` | Base64 编码的 Developer ID `.p12` 证书 |
| `APPLE_CERT_PASSWORD` | `.p12` 导入密码 |
| `LUMEN_SIGN_IDENTITY` | 签名身份名称（如 `Developer ID Application: ...`） |
| `LUMEN_MANIFEST_KEY_PEM` | 与该证书公钥配对的 PEM 私钥，用于生成 `lumen-update.json.cms` |
| `APPLE_NOTARY_KEY_ID` / `APPLE_NOTARY_ISSUER_ID` / `APPLE_NOTARY_KEY_P8` | （可选）App Store Connect API 密钥，启用 `xcrun notarytool` 自动公证与装订 |

Path A 发布产物会额外包含 **`lumen-update.json.cms`**。用户侧已签名的 Lumen 会自动校验 CMS 签名、ZIP SHA-256 及组件 Designated Requirement，随后原子交换并自动重启完成原位更新。

---

## 3. 本机干跑与 Homebrew Cask 模板同步

在本地 Apple Silicon Mac 上干跑校验打包产出：

```sh
printf 'Release notes preview\n' > /tmp/lumen-notes.txt
LUMEN_ALLOW_UNSIGNED=1 scripts/package-release.sh /tmp/lumen-dist /tmp/lumen-notes.txt
(cd /tmp/lumen-dist && shasum -a 256 -c SHA256SUMS.txt)
```

发布后如需同步 [`packaging/homebrew/Casks/lumen.rb`](../packaging/homebrew/Casks/lumen.rb)，将 `version` 与 `sha256` 更新为 `lumen-update.json`（或 `SHA256SUMS.txt`）中 `Lumen-macos-arm64.zip` 对应的值即可。
