# 本机开发签名与辅助功能授权

Menu Tidy 的辅助功能授权与应用代码签名身份关联。ad hoc 临时签名没有证书身份，修改代码后通常产生不同的代码哈希。系统设置仍显示旧条目已打开，并不代表新二进制满足旧授权记录的签名要求。

本项目提供显式初始化的本机开发证书，供当前 Mac 的持续开发使用。它不替代公开分发所需的 Apple Developer ID、Hardened Runtime 和公证，也不会自动获得辅助功能权限。

## 初始化与正常构建

在仓库根目录、以当前登录用户执行，不要使用 `sudo`：

```sh
./scripts/init-local-signing.sh --create
./scripts/build.sh release
```

初始化第一次创建本地身份；再次执行会验证并复用现有身份，不会生成新的证书。普通构建永远不会创建证书或钥匙串。初始化的两个临时应用具有不同的代码哈希，均须通过同一证书要求，成功后才写入完成配置。它们不会运行或申请任何权限。

构建按以下顺序选择签名：

1. 显式设置的 `CODE_SIGN_IDENTITY`，可搭配 `CODE_SIGN_KEYCHAIN`。
2. 本机已成功初始化的 Menu Tidy 开发证书。
3. 没有上述身份时，使用带明确警告的 ad hoc 临时签名。

任何已配置身份签名失败都会停止构建，不会悄悄降级为临时签名。初始化只完成了一部分时也会停止，避免误覆盖现有身份。

已有 Apple 开发者签名身份时，可直接指定，保留 Apple 默认生成的 designated requirement：

```sh
CODE_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)' ./scripts/build.sh release
```

需要限定钥匙串时：

```sh
CODE_SIGN_IDENTITY='证书的 40 位十六进制 SHA-1 指纹' \
CODE_SIGN_KEYCHAIN='/absolute/path/to/development.keychain-db' \
./scripts/build.sh release
```

外部钥匙串由其所有者负责解锁及授权。本项目不会读取其他钥匙串的密码。显式 `CODE_SIGN_IDENTITY=-` 可以强制临时签名，但仍会显示授权失效风险。

## 本机身份的存储与访问

所有本机材料放在 `~/Library/Application Support/Menu Tidy/Signing/`，不在仓库内：

- `MenuTidy-Development.keychain-db`：独立钥匙串，保存本机私钥和证书。
- `keychain-password`：随机生成的本机自动构建密码。
- `certificate.der`：公开证书。
- `identity.json`：公开指纹和应用标识；不包含私钥或密码。

目录权限为 `0700`，文件权限为 `0600`，加载时检查所有者、权限及符号链接。只有当前用户的进程可按这些文件权限读取；这不是针对已控制当前用户账户的攻击者的隔离机制。请勿提交、上传或分享整个 Signing 目录，也不要将密码内容粘贴到日志中。

证书采用 RSA 3072 位、SHA-256 证书签名、代码签名专用扩展及十年有效期。初始化时临时生成的私钥 PEM 和 PKCS#12 均经过密码加密，并在导入结束后删除。导入后的私钥设置为不可导出。初始化失败保留钥匙串供诊断，避免自动删除唯一密钥。

私钥的应用访问列表指定 `/usr/bin/codesign`，并仅对新建专属钥匙串的签名私钥设置 `apple-tool:,apple:` partition list，以支持系统签名工具的非交互访问。`security(1)` 要求 `codesign` 使用的私钥 partition list 包含 `apple:`。这意味着该钥匙串中此私钥允许符合对应 Apple partition 的工具访问；不是“允许任何应用访问”。脚本不使用 `security import -A`，不修改其他钥匙串的 ACL，不调用 `add-trusted-cert`，不修改系统或用户证书信任设置，不关闭 Gatekeeper/SIP。

密码通过 `/usr/bin/security -q -i` 的标准输入管道传递，不进入进程参数、环境变量或输出；OpenSSL 只接收密码文件路径。不要用调试器、系统调用追踪或修改脚本输出这条内部输入。每次本机签名仅在需要时解锁专属钥匙串，结束后重新锁定。系统 `security create-keychain` 可能将新钥匙串加入当前用户的搜索列表；脚本不会将其设为默认钥匙串，签名始终显式限定该文件。

本机身份的 designated requirement 同时固定应用标识和证书：

```text
designated => identifier "dev.hdh.MenuTidy" and certificate leaf = H"证书 SHA-1 指纹"
```

这里的 SHA-1 是 Apple requirement language 指定的证书标识格式，证书本身使用 SHA-256 签名。要求没有只凭 bundle identifier 放行，也没有 `anchor trusted`。只要保持相同证书和私钥，不同代码内容仍满足同一身份要求。丢失身份材料或换证书意味着需要重新授权；不能从公开证书恢复私钥。

## 修复已经过期的授权条目

完成应用修改及最后一次构建，然后执行以下步骤：

1. 从 Menu Tidy 设置窗口退出正在运行的应用，再执行 `./scripts/install.sh`。默认安装位置为 `/Applications/Menu Tidy.app`；如需覆盖目录，显式设置 `MENU_TIDY_INSTALL_DIR` 为绝对路径。目标不可写时脚本会停止，不会提权或静默选择其他目录。
2. 在系统设置的辅助功能权限列表中移除 **Menu Tidy 自己的旧条目**，再通过添加按钮选择该固定安装路径，并打开授权。只有旧条目对应过期身份时才需要此修复。
3. 从该安装路径启动 Menu Tidy，点击重新检查；确认实际菜单栏项目能够读取并进行获准的分类操作。

无需重置其他应用的权限，也不要编辑 TCC 数据库。系统要求认证时，由用户在 macOS 原生界面完成。第一次从临时签名切换为证书签名仍然属于身份变更，不能继承旧代码哈希的授权。

签名连续性验证应包括：记录已授权状态，修改应用并用同一证书重建，退出旧进程后安装，再启动检查。`codesign --verify --strict` 只证明签名完整性；初始化的双样本检查只证明两个版本满足同一证书要求。它们均不能单独证明 macOS 27 的辅助功能授权或事件投递权限已在运行中生效。

## 初始化失败

脚本不会覆盖已有但不完整的 Signing 目录。先保留该目录，检查报错及专属钥匙串状态，避免丢失已经用于授权的证书。不要通过信任根证书、授予任何应用访问私钥、关闭系统保护或批量重置 TCC 来绕过失败。若签名工具在这台系统上拒绝该本地证书，请改用真实 Apple Development / Developer ID 身份并通过 `CODE_SIGN_IDENTITY` 指定。

若证书及私钥已经成功导入，只是后续验证被中断，可执行 `./scripts/init-local-signing.sh --resume`。此模式不会创建、导入或替换身份，只在现有身份通过两份不同代码样本的固定证书要求验证后补全配置。若导入从未成功，它会停止，保留材料供诊断。

相关 Apple 资料：[Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)、[Code Signing Requirement Language](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html)、[TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)、[TN3161](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates)。
