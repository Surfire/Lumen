# 翻译

打开 Lumen 的「翻译」，选源语言和目标语言，输入文本后点击「翻译」。发送前面板会显示所选 API 基址和模型。文本和译文保留在面板内存中，翻译请求只携带选定语言、明确输入的文本和模型 ID。

## 使用现有 oMLX

1. 在「模型和提供商设置」中保留本机预设 `http://127.0.0.1:8000/v1`，或填入 oMLX 的实际端口。
2. 若 oMLX 启用了认证，可在面板安全输入该服务的 API 密钥。点击「测试连接」检查模型接口，或点击「列出模型」，从已提供的模型中选一个对话模型。也可以手工填写模型 ID。
3. 点击「保存提供商」。以后可以切换已保存的提供商，每个提供商独立保存名称、基址和模型 ID。

可用「新建提供商」添加其他 OpenAI 兼容服务。基址应指向 API 路径，例如服务文档所给的 `…/v1`，路径留空时使用 `/v1`。远程服务要求 HTTPS，HTTP 仅限 IPv4 或 IPv6 本机回环地址。模型列表和翻译分别调用 `GET /models` 与 `POST /chat/completions`。测试和列出模型使用当前草稿，不保存草稿。密钥只在明确保存后存入 macOS 钥匙串，并绑定提供商和端点。更改端点后不会把旧端点的密钥发送过去。

模型和提供商设置参考了 Type4Me 的自定义兼容服务、显式测试和模型发现。接口按 oMLX 的公开文档实现。测试使用本机合成服务器和合成密钥。[Type4Me 模型设置](https://github.com/joewongjc/type4me/pull/277) · [oMLX API](https://github.com/jundot/omlx#api-compatibility)

## 接入启动器和验证

在 Swift 编译输入中加入 `app/TranslationClient.swift`、`app/TranslationModel.swift`、`app/TranslationPanel.swift`。菜单栏或启动器动作使用 `NSHostingView(rootView: TranslationPanel())` 创建原生面板。推荐面板最小内容区为 600 × 495 点，打开时不会发出请求。

macOS 14 及以上的打包环境在 `Info.plist` 的 `NSAppTransportSecurity.NSExceptionDomains` 下为 `127.0.0.1` 和 `::1` 分别设置 `NSExceptionAllowsInsecureHTTPLoads=true`，以支持本机 HTTP oMLX。应用没有为远端配置 HTTP 例外。[Apple ATS 例外文档](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains)

```sh
python3 scripts/smoke-translation.py
```

无窗口测试通过面板使用的状态模型发送真实回环 HTTP 请求。它验证提供商设置、模型发现、翻译、端点变更时的密钥隔离、拒绝重定向、取消、超时及认证错误。测试注入内存钥匙串适配器。真实 oMLX 的健康端点有响应，模型列表需要认证，开发验证未读取现有凭证或发送推理请求。
