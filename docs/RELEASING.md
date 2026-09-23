# 构建与发布

Menu Tidy 0.3.1 采用预发布流程。普通提交和 Pull Request 会生成供检查的构建产物；只有推送与应用版本一致的 `v*` 标签，才会尝试创建 GitHub Release。所有自动发布的版本都标为 **Prerelease**，不会替换稳定版本的 Latest 标记。

工作流定义在 [ci.yml](../.github/workflows/ci.yml)。工作流文件、脚本检查或本地打包成功，都不代表某次 GitHub 构建已经通过；以对应提交的 Actions 运行结果和 Release 中的实际附件为准。

## 自动检查

每次分支 push、Pull Request 和 `v*` 标签 push 都运行两个原生构建任务：

| 架构 | GitHub runner | 工具链 |
| --- | --- | --- |
| Apple Silicon / `arm64` | `macos-15` | Xcode 26.3 / Swift 6.2.x |
| Intel / `x86_64` | `macos-15-intel` | Xcode 26.3 / Swift 6.2.x |

工作流通过 `DEVELOPER_DIR` 固定 Xcode 路径，并检查实际 runner 架构。每个任务执行 `./scripts/check.sh --full` 和 `./scripts/package.sh`，完成检查后上传独立架构的应用压缩包、SHA-256 文件和构建元数据。Actions artifacts 保留 14 天。

普通分支 push 和 Pull Request 使用显式的 ad hoc 签名 `CODE_SIGN_IDENTITY=-`。这些构建用于验证代码，签名身份不会跨构建保持稳定。CI 不会自动初始化开发证书，也不需要用于发布的签名 secrets。Pull Request 使用 `pull_request` 事件，构建任务仅授予仓库内容读取权限。

维护者可在 Actions 中手动运行此工作流，勾选 `validate_signing`，在打标签前验证两个架构的真实签名打包。该选项默认关闭；开启时使用专用 secrets，但手动运行始终不创建 Release。命令行等效操作为 `gh workflow run ci.yml --ref main -f validate_signing=true`。

当前最低部署目标是 macOS 13。CI 在 macOS 15 的两个架构上测试和编译，不构成 macOS 13 运行验收，也不会自动完成辅助功能授权、图标移动、展开与收起、多显示器等桌面交互测试。macOS 27 的既有实机观察见[验收记录索引](README.md#验收记录)；新版本仍需针对实际使用场景验收。

## 本地打包

在干净的工作区中运行：

```sh
./scripts/check.sh --full
./scripts/package.sh
```

打包脚本读取 `Resources/Info.plist` 的版本，构建本机原生架构，检查 Mach-O 架构和应用签名，然后产生以下文件。以 0.3.1 的 Apple Silicon 包为例：

```text
dist/Menu-Tidy-0.3.1-macos-arm64.zip
dist/Menu-Tidy-0.3.1-macos-arm64.zip.sha256
dist/Menu-Tidy-0.3.1-macos-arm64.zip.metadata.json
```

Intel runner 产生同名规则的 `x86_64` 文件。当前发布两个独立架构包，不生成 Universal 包。元数据记录源码提交、工作区是否有改动、版本、架构、最低系统版本、工具链、摘要和签名 designated requirement；不要把签名自检等同于 Apple 公证或 Gatekeeper 放行。

应用先由 `ditto` 打包成 zip，再作为一个文件上传，避免直接上传 `.app` 目录时 Actions artifact 丢失可执行文件的权限。下载后可以在文件所在目录检查完整性：

```sh
shasum -a 256 -c Menu-Tidy-0.3.1-macos-arm64.zip.sha256
```

SHA-256 用于检查文件内容是否与发布的摘要一致，不替代发行者身份认证。

## 发布签名的前置配置

标签发布要求仓库已配置两个 Actions secrets：

| Secret | 用途 |
| --- | --- |
| `MACOS_SIGNING_P12_BASE64` | 专用于 CI 发布的 PKCS#12 签名身份的 Base64 编码 |
| `MACOS_SIGNING_PASSWORD` | 该 PKCS#12 文件的密码 |

材料必须来自明确授权准备的专用身份。不要把本机现有开发私钥复制到仓库，也不要复用 [本地签名说明](LOCAL-SIGNING.md) 中不可导出的开发私钥。证书、私钥、密码和包含它们的编码都不应写入 Git、文档或工作流日志。准备材料、上传 secrets 与第一次真实 CI 发布是不同步骤；只有仓库 secrets 配置完成后，标签任务才具备签名条件。

标签任务调用 `scripts/ci-signing.py install`，在 runner 的临时目录建立签名钥匙串，将其加入当前用户搜索列表，并通过实际签名预检后把签名参数提供给后续构建。缺少 secrets 或导入失败时任务失败，不降级成 ad hoc 发布。任务退出时执行 `scripts/ci-signing.py cleanup` 清理临时材料及对应搜索列表项，保留原有钥匙串配置。两个架构包必须使用相同的证书约束，发布前会检查这一点。

当前专用自签名身份用于保持发行签名连续性，**不是 Apple Developer ID，也不表示应用经过 Apple notarization**。发布元数据会明确记录公证状态。后续接入 Developer ID 和公证时，需要同时更新签名流程、校验与用户说明，不能只改变 Release 文案。

## 发起一个版本

1. 更新 `Resources/Info.plist` 的版本及构建号，并在 `CHANGELOG.md` 写好对应版本条目，包括已知限制。
2. 完成必要的实机验收；运行完整检查，提交全部准备发布的改动，使工作区保持干净。
3. 确认远端、GitHub 登录身份与发布签名 secrets 配置正确，再运行发布脚本：

   ```sh
   ./scripts/release.sh 0.3.1
   ```

发布脚本接收不带 `v` 的版本号，要求从已推送到远端的 `main` 分支发布，且当前提交最近一次分支 push 工作流已成功完成。它会校验版本、标签、GitHub 登录状态、工作区及对应 CI 结果，执行完整检查，并创建和推送 annotated tag。不要通过强制移动已有标签来重复发布同一个版本。

标签必须是应用版本前加 `v`，例如 `v0.3.1` 对应 `CFBundleShortVersionString` 的 `0.3.1`。推送标签后，工作流重新测试并构建两个架构，成功后才进入发布任务。

## 发布前的自动校验

独立的发布任务只在标签事件、且两个构建任务都成功时执行，只有这个任务取得 `contents: write` 权限。它下载本次工作流的产物，检查：

- 下载的 Actions artifact digest 必须匹配，失败会终止任务。
- 两个 zip 及各自的 checksum、metadata 共六个文件必须齐全，不能出现额外文件。
- 每个 zip 的实际 SHA-256、checksum 文件名与 metadata 中的摘要必须一致。
- metadata 的版本、构建号、bundle identifier、最低系统版本、架构和 commit 必须与本次标签源码相符，工作区必须为干净状态。
- 两个架构必须具有一致且固定到证书的 designated requirement。
- 发布说明必须能从 `CHANGELOG.md` 中提取对应版本条目。

校验通过后，工作流使用 GitHub CLI 创建 **draft prerelease** 并上传全部六个附件；再次检查远端 draft 的附件名和大小后，才取消 draft 状态，公开为 prerelease。创建时使用 `--verify-tag`，不会顺便创建一个指向默认分支的新标签。若该标签已有 Release，即使仍是 draft，也会失败并保留原有内容，不覆盖或删除附件。

如果网络或上传失败，可能留下未公开的 draft。先检查 Actions 日志和 draft 的实际状态，处理残留草稿后再决定重跑；工作流不会自动删除旧发布，也不会把缺少附件的 draft 公开。

## 维护依据

runner 镜像和 Actions 版本会更新。本流程使用明确的 runner 标签和 Xcode 版本，并将 GitHub Actions 锁定到完整 commit SHA；升级时应重新核对官方发布信息并运行两个架构的任务。

- [GitHub 托管 runner 标签与架构](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [macOS 15 Apple Silicon 镜像工具清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)、[Intel 镜像工具清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)
- [Xcode 26.3 发布说明](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_3-release-notes)
- [upload-artifact 的权限保存限制](https://github.com/actions/upload-artifact#permission-loss)、[download-artifact 的 digest 校验](https://github.com/actions/download-artifact#v8---whats-new)
- [GitHub CLI 创建 Release](https://cli.github.com/manual/gh_release_create)、[Actions 安全配置](https://docs.github.com/en/actions/how-tos/security-for-github-actions/security-guides/security-hardening-for-github-actions)
