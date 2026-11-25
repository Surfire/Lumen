# 在同一路径安装和更新 Lumen

日用安装路径默认为 `~/Applications/Lumen.app`。更新复用此前的代码签名身份。Apple 用代码签名的指定要求（DR）识别后续版本。开发用临时签名（ad hoc）的 DR 绑定于具体构建，重新签名后可能再次触发授权提示。[Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

## 首次安装和后续更新

用已经可用的、专用于 Lumen 的命名代码签名身份构建。每次更新使用同一证书和私钥。变量接受身份名称或证书 SHA-1 指纹。若该身份位于单独的钥匙串，可用 `LUMEN_SIGN_KEYCHAIN` 指定该文件。构建工具只用现有身份签名，不创建身份或修改钥匙串设置。

```sh
LUMEN_SIGN_IDENTITY='Lumen Local Code Signing' scripts/build-app.sh
```

在菜单栏自行退出所有运行中的 Lumen 实例，再运行安装器。首次安装和更新使用同一命令。

```sh
scripts/install-app.py install target/Lumen.app
open "$HOME/Applications/Lumen.app"
```

如果一开始就选择其他路径，安装和更新时都传入同一个 `--destination /明确路径/Lumen.app`。安装器核对主程序和四个内置可执行工具的标识符、签名及签名证书。更新还会让新旧组件各自验证对方的 DR，并拒绝证书变更。通过验证的副本才会在同一卷上原子替换到日用路径。这个签名流程用于本机安装，不包含 Gatekeeper 公证流程。[Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)

不设置签名身份时，构建仍会生成开发用的 `target/Lumen.app`。安装器拒绝安装这种临时签名包。

## 从已安装的临时签名版本迁移

如果日用路径已经有临时签名的 Lumen，用同一个安装器明确执行一次迁移。换用命名身份后，macOS 可能重新询问文件夹权限。若日用路径目前为空，使用普通首次安装命令。

```sh
scripts/install-app.py install target/Lumen.app --migrate-ad-hoc
```

该选项只允许用证书签名包替换现有的临时签名包。证书签名安装之间的身份变更仍会被拒绝。安装器不会终止或启动应用。安装、升级和回滚只交换应用包，不修改 TCC 授权或 `~/Library/Application Support/Lumen` 内的索引和数据。

## 回滚应用包

成功替换后，安装器会打印保留的旧应用路径。退出 Lumen，把该路径作为安装源再次运行安装器，保持原来的目标路径。回滚仍需通过身份验证。迁移前的临时签名版本也会存档，但不能通过日用安装器恢复。应用包回滚不还原数据库，旧版本能否读取已升级的数据取决于数据格式的兼容性。

## 验证

```sh
python3 scripts/smoke-install-app.py
```

测试只使用临时目录里的自写 Mach-O 测试包、短期证书和临时钥匙串。它验证同证书更新、不同证书或不兼容 DR 的拒绝、一次性迁移和两种回滚路径，并模拟应用运行时的拒绝。测试检查索引哨兵及用户钥匙串默认值和搜索列表保持原样。测试不会启动应用或改动真实文件访问授权。
