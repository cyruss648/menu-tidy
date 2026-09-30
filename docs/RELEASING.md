# 构建与发布

Menu Tidy 当前版本为 **0.6.3（build 59）**。本轮独立托盘与原生隐藏的本地验收见[当前托盘记录](TRAY-EXPERIENCE.md)；历史隔离更新器的签名安装、重启与偏好保留证据仍分别记录。`SPARKLE_PRIVATE_KEY` 已获用户明确授权并上传。下面的流程只在对应 Actions 与 Release 实际完成后构成公开发布，不把本地打包视为 GitHub 发布物安装验收。

普通提交和 Pull Request 会生成供检查的构建产物；只有推送与应用版本一致的 `v*` 标签，才会尝试创建 GitHub Release。**版本带预发布后缀时进入 preview，并标为 Prerelease；没有后缀时进入 stable。** 例如 `v0.6.0-beta.1` 不改变稳定版 Latest，`v0.6.0` 则作为稳定版发布并更新 Latest。不要用文案中的“预览版”代替实际版本后缀。

工作流定义在 [ci.yml](../.github/workflows/ci.yml)。工作流文件、脚本检查或本地打包成功，都不代表某次 GitHub 构建已经通过；以对应提交的 Actions 运行结果和 Release 中的实际附件为准。

## 自动检查

除专门存放更新 feed 的 `updates` 分支外，每次分支 push、Pull Request 和 `v*` 标签 push 都运行两个原生构建任务：

| 架构 | GitHub runner | 工具链 |
| --- | --- | --- |
| Apple Silicon / `arm64` | `macos-15` | Xcode 26.3 / Swift 6.2.x |
| Intel / `x86_64` | `macos-15-intel` | Xcode 26.3 / Swift 6.2.x |

工作流通过 `DEVELOPER_DIR` 固定 Xcode 路径，并检查实际 runner 架构。每个任务执行 `./scripts/check.sh --full` 和 `./scripts/package.sh`，完成检查后上传独立架构的应用压缩包、SHA-256 文件和构建元数据。Actions artifacts 保留 14 天。

普通分支 push 和 Pull Request 使用显式的 ad hoc 签名 `CODE_SIGN_IDENTITY=-`。这些构建用于验证代码，签名身份不会跨构建保持稳定。CI 不会自动初始化开发证书，也不需要用于发布的签名 secrets。Pull Request 使用 `pull_request` 事件，构建任务仅授予仓库内容读取权限。

维护者可在 Actions 中手动运行此工作流，勾选 `validate_signing`，在打标签前验证两个架构的真实签名打包与 Sparkle 归档签名。该选项默认关闭；开启时需要下述三项专用 secrets，但手动运行始终不创建 Release，也不发布 feed。命令行等效操作为 `gh workflow run ci.yml --ref main -f validate_signing=true`；密钥配置和授权完成前不要发起该任务。

当前最低部署目标是 macOS 13。CI 在 macOS 15 的两个架构上测试和编译，不构成 macOS 13 运行验收，也不会自动完成辅助功能授权、图标移动、展开与收起、多显示器等桌面交互测试。macOS 27 的既有实机观察见[验收记录索引](README.md#验收记录)；新版本仍需针对实际使用场景验收。

## 本地打包

在干净的工作区中运行：

```sh
./scripts/check.sh --full
./scripts/package.sh
```

打包脚本读取 `Resources/Info.plist` 的版本，构建本机原生架构，检查 Mach-O 架构和应用签名，然后产生以下文件。以 0.6.0 的 Apple Silicon 包为例：

```text
dist/Menu-Tidy-0.6.0-macos-arm64.zip
dist/Menu-Tidy-0.6.0-macos-arm64.zip.sha256
dist/Menu-Tidy-0.6.0-macos-arm64.zip.metadata.json
```

Intel runner 产生同名规则的 `x86_64` 文件。当前发布两个独立架构包，不生成 Universal 包。元数据记录源码提交、工作区是否有改动、版本、架构、最低系统版本、工具链、摘要和签名 designated requirement；不要把签名自检等同于 Apple 公证或 Gatekeeper 放行。

应用先由 `ditto` 打包成 zip，再作为一个文件上传，避免直接上传 `.app` 目录时 Actions artifact 丢失可执行文件的权限。下载后可以在文件所在目录检查完整性：

```sh
shasum -a 256 -c Menu-Tidy-0.6.0-macos-arm64.zip.sha256
```

SHA-256 用于检查文件内容是否与发布的摘要一致，不替代发行者身份认证。

## 发布签名的前置配置

标签发布和显式启用的手动签名验证要求仓库已配置三项 Actions secrets：

| Secret | 用途 |
| --- | --- |
| `MACOS_SIGNING_P12_BASE64` | 专用于 CI 发布的 PKCS#12 签名身份的 Base64 编码 |
| `MACOS_SIGNING_PASSWORD` | 该 PKCS#12 文件的密码 |
| `SPARKLE_PRIVATE_KEY` | 专用于更新归档与 feed 的 EdDSA 私钥，与应用内 `SUPublicEDKey` 对应 |

材料必须来自明确授权准备的专用身份。不要把本机现有开发私钥复制到仓库，也不要复用 [本地签名说明](LOCAL-SIGNING.md) 中不可导出的开发私钥。证书、私钥、密码和包含它们的编码都不应写入 Git、文档或工作流日志。准备材料、上传 secrets 与第一次真实 CI 发布是不同步骤；只有仓库 secrets 配置完成后，标签任务才具备签名条件。

Sparkle 私钥独立于 macOS 代码签名证书，其公钥写入 `Resources/Info.plist`，并要求 `SURequireSignedFeed=true` 与 `SUVerifyUpdateBeforeExtraction=true`。`SPARKLE_PRIVATE_KEY` 已经用户明确授权，经标准输入上传至 `cyruss648/menu-tidy` 的 GitHub Actions Secrets，更新时间为 `2026-09-24T19:31:34Z`；私钥未写入源码或日志。该配置状态不等于新的远端签名与发布流水线已通过，仍需按实际运行结果验证。工作流通过环境变量读取私钥并经标准输入交给固定版本的官方签名工具，不把私钥放在命令参数中。签名后另用应用内公钥验证，公私钥不匹配时停止。

标签任务调用 `scripts/ci-signing.py install`，在 runner 的临时目录建立签名钥匙串，将其加入当前用户搜索列表，并通过实际签名预检后把签名参数提供给后续构建。缺少 secrets 或导入失败时任务失败，不降级成 ad hoc 发布。任务退出时执行 `scripts/ci-signing.py cleanup` 清理临时材料及对应搜索列表项，保留原有钥匙串配置。两个架构包必须使用相同的证书约束，发布前会检查这一点。

当前专用自签名身份用于保持发行签名连续性，**不是 Apple Developer ID，也不表示应用经过 Apple notarization**。发布元数据会明确记录公证状态。后续接入 Developer ID 和公证时，需要同时更新签名流程、校验与用户说明，不能只改变 Release 文案。

Sparkle 2.10.0 的 framework 和内部辅助组件嵌入应用后，由构建签名流程从内到外处理；完成应用代码签名和最终 zip 打包后，才签名归档。不要签名后重新压缩或改写归档。集成结构、密钥连续性与首次升级要求见[应用内更新说明](AUTO-UPDATE.md)。

## 发起一个版本

1. 更新唯一版本源 `Resources/Info.plist` 的版本及递增构建号，明确 stable / preview 通道，并在 `CHANGELOG.md` 写好对应版本条目，包括新权限、兼容限制和升级说明。构建号须高于已发布的两个通道，同一通道语义版本也必须递增。发布脚本只提取该版本的章节，不能把准备发布的变化留在 `Unreleased` 中。
2. 完成必要的实机验收；运行完整检查，提交全部准备发布的改动，使工作区保持干净。
3. 确认远端、GitHub 登录身份与发布签名 secrets 配置正确，再运行发布脚本：

   ```sh
   ./scripts/release.sh 0.6.0
   ```

发布脚本接收不带 `v` 的版本号，要求从已推送到远端的 `main` 分支发布，且当前提交最近一次分支 push 工作流已成功完成。它会使用与最终 feed 相同的规则校验语义版本和构建号，再校验标签、GitHub 登录状态、工作区及对应 CI 结果。完整检查结束后，`release-preflight.py` 会只读获取远端 `updates` 分支、验签两个架构的既有 feed，并再次检查构建号和同通道版本递增，然后才创建和推送 annotated tag。网络或认证失败不会被当作首次发布；只在明确没有该分支时允许没有历史 feed。远端内容仅存于临时目录，不 checkout 远端代码，也不改变本地分支。不要通过强制移动已有标签来重复发布同一个版本。

标签必须是应用版本前加 `v`，例如 `v0.6.0` 对应 `CFBundleShortVersionString` 的 `0.6.0`。推送标签后，工作流重新测试并构建两个架构，成功后才进入发布任务。

## 发布前的自动校验

独立的 macOS 发布任务只在标签事件、且两个构建任务都成功时执行，只有这个任务取得 `contents: write` 权限。任务串行发布，避免两个版本同时更新 feed；它下载本次工作流的产物，检查：

- 下载的 Actions artifact digest 必须匹配，失败会终止任务。
- 两个 zip 及各自的 checksum、metadata、`.zip.eddsa.json` 共八个文件必须齐全，不能出现额外文件。
- 每个 zip 的实际 SHA-256、checksum 文件名与 metadata 中的摘要必须一致。
- metadata 的版本、构建号、bundle identifier、最低系统版本、架构和 commit 必须与本次标签源码相符，工作区必须为干净状态。
- 两个架构必须具有一致且固定到证书的 designated requirement。
- 每个归档的 EdDSA 签名必须由应用内公钥独立验证通过，签名记录的文件名、长度与 SHA-256 必须匹配。
- 若 `updates` 分支已有 feed，先验证其签名、通道与架构，拒绝构建号倒退和同一通道版本不递增；已有错误 feed 不当作空分支覆盖。
- 发布说明必须能从 `CHANGELOG.md` 中提取对应版本条目。

校验通过并在临时目录完成两个架构的签名 feed 后，工作流使用 GitHub CLI 创建 **draft Release** 并上传全部八个附件；再次检查远端 draft 的附件名和大小后，才取消 draft 状态，按版本通道公开为稳定版或 prerelease。创建时使用 `--verify-tag`，不会顺便创建一个指向默认分支的新标签。若该标签已有 Release，即使仍是 draft，也会失败并保留原有内容，不覆盖或删除附件。

如果网络或上传失败，可能留下未公开的 draft。不要直接删除草稿或重跑整条任务；先按下方「中断后的恢复」核对原产物和远端状态。工作流不会自动删除旧发布，也不会把缺少附件的 draft 公开。

## 发布更新 feed

只有 Release 已经公开、下载附件已齐全后，工作流才将本次通道的两份签名 feed 提交并推送到 `updates` 分支，不使用 force push，不改变另一通道。首次发布创建该专用分支；其后沿现有分支增量提交。对应文件为：

```text
stable/appcast-arm64.xml
stable/appcast-x86_64.xml
preview/appcast-arm64.xml
preview/appcast-x86_64.xml
```

应用通过 `https://raw.githubusercontent.com/cyruss648/menu-tidy/updates/<通道>/appcast-<架构>.xml` 读取 feed。每份 feed 当前仅包含该通道该架构的最新版本，并链接同一版本的公开 GitHub Release 归档；更新说明嵌入已签名的 XML。对 feed 或说明的任何修改都需要重新签名。

`scripts/fetch-sparkle-tools.py` 验证固定 Sparkle 2.10.0 官方工具归档的 SHA-256；`scripts/generate-update-feed.py sign` 签名最终 zip，`generate` 检查旧 feed 与全部产物后生成新的签名 XML。具体参数见[应用内更新说明](AUTO-UPDATE.md#签名工具接口)。这些脚本只准备文件，工作流负责公开 Release 和推送 feed。

若 Release 已公开而 feed 推送失败，Release 附件可能已可手动下载，应用仍看到旧 feed。此时应查明分支、权限或网络问题，再按原版本、原归档与原签名恢复发布；不要强制改标签、覆盖已有 Release，或绕过旧 feed 验证。当前工作流会拒绝重复创建已有 Release，不能将重新运行整个发布任务当作无条件修复。

## 中断后的恢复

恢复沿用正常发布的前置条件：该版本功能已完成实机验收，且维护者有合法的发布权限与签名材料。以下操作不是跳过验收的入口，必须保留对应版本的实机范围和未覆盖限制。保留失败运行的日志和原始 Actions artifacts，不移动标签、不重新打包、不重新签已有归档，不使用 `--clobber` 或 force push。

1. 记录失败 workflow 的 run ID、完整 commit、tag 和 Release ID。使用 `gh release view "$release_tag" --repo cyruss648/menu-tidy --json tagName,isDraft,isPrerelease,assets` 查看真实状态；核对标签实际指向的 commit，不能仅凭 Release 标题判断。若 Actions 原产物已过期或无法确定其来源，停止恢复，重新走一个新版本的构建与验收流程。
2. 用 `gh run download "$release_run_id" --repo cyruss648/menu-tidy --name menu-tidy-macos-arm64 --dir "$release_original"` 和对应 `x86_64` artifact 下载原工作流产物到同一个空目录。应正好有两个 zip 与各自三份校验文件，共八个文件。不要使用本机重新编译的替代包。
3. 用 `gh release download "$release_tag" --repo cyruss648/menu-tidy --dir "$release_downloaded"` 将 GitHub 当前附件下载到另一个空目录。下载失败不能当作“没有附件”；先通过 Release API 的附件清单核对。对每个已存在附件做逐字节 SHA-256 比较，而不只是比较文件名或大小。以下命令只读取本地下载副本；路径变量需要事先指向上述两个空目录：

   ```sh
   python3 - "$release_original" "$release_downloaded" <<'PY'
   import hashlib
   from pathlib import Path
   import sys

   original, downloaded = map(Path, sys.argv[1:])
   expected = {path.name: path for path in original.iterdir() if path.is_file()}
   actual = {path.name: path for path in downloaded.iterdir() if path.is_file()}
   if len(expected) != 8 or not actual.keys() <= expected.keys():
       raise SystemExit('Original payload or remote asset names are incomplete/unexpected')
   for name, path in actual.items():
       if (path.is_symlink() or expected[name].is_symlink()
               or hashlib.sha256(path.read_bytes()).digest()
               != hashlib.sha256(expected[name].read_bytes()).digest()):
           raise SystemExit('Remote asset differs from the original workflow: ' + name)
   print('Matching existing assets:', len(actual))
   print('Missing assets:', ', '.join(sorted(expected.keys() - actual.keys())) or 'none')
   PY
   ```

   八个文件名、版本、build、commit、公钥和 ZIP 签名仍须由原标签源码中的 `generate-update-feed.py` 完整校验；上述字节比较不能替代产物身份和签名验证。
4. 若仍是 draft，只有已存在附件全部与原产物一致时，才可用 `gh release upload "$release_tag" "$missing_original_file" --repo cyruss648/menu-tidy` 补齐**缺失**附件，绝不能加 `--clobber`。补齐后重新下载并验证全部八个附件，同时核对 draft 的 tag、渠道和 release notes。任何已存在附件不一致，都应停止并调查，不能用覆盖附件消除差异。尚未公开的 draft 在全部检查通过以前保持 draft。
5. 若 Release 已公开，必须证明八个公开附件与原 Actions 产物逐一完全一致，再恢复 feed。缺失或不一致时停止，不能覆盖已公开附件。若远端 feed 已经是同一 tag/build，先验签并核对 enclosure 的 URL、长度和归档签名；内容与公开原产物相符时，该版本已发布完成，无需再次写入。若 feed 已前进到更新版本，不能让旧版本恢复任务将它倒退。
6. 对仍需推进的 feed，从**当前**远端 `updates` 分支建立单独临时 checkout；若尚无该分支，按工作流首次发布步骤创建。使用原标签 checkout 中的工具、原八个产物和原 release notes，运行文档中的 `generate-update-feed.py generate` 命令，让它重新验签历史 feed、检查递增关系、验证原 ZIP，并签出当前通道的两个 XML。此步骤需要原专用更新密钥，不能临时生成新密钥绕过验证。若增长或签名检查失败，停止；不要修改历史 feed 来让检查通过。
7. 对完整 draft，只有第 6 步的所有检查通过且原附件复核一致后，才按原渠道公开 Release；然后确认其附件可以访问。对已公开 Release，保持原发布内容。最后只提交本次通道的两份已签 XML，普通推送 `updates` 分支。推送被拒绝时重新读取远端并判断是否已完成或被更新版本取代，不能 force push。

当前自动发布任务仍保守拒绝已存在的 Release，不会自动完成上述恢复。`release-preflight.py --tag vX.Y.Z` 可单独执行只读的版本与历史 feed 检查，但它既不发布文件，也不证明实机功能已验收。

## 维护依据

runner 镜像和 Actions 版本会更新。本流程使用明确的 runner 标签和 Xcode 版本，并将 GitHub Actions 锁定到完整 commit SHA；升级时应重新核对官方发布信息并运行两个架构的任务。

- [GitHub 托管 runner 标签与架构](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [macOS 15 Apple Silicon 镜像工具清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)、[Intel 镜像工具清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)
- [Xcode 26.3 发布说明](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_3-release-notes)
- [upload-artifact 的权限保存限制](https://github.com/actions/upload-artifact#permission-loss)、[download-artifact 的 digest 校验](https://github.com/actions/download-artifact#v8---whats-new)
- [GitHub CLI 创建 Release](https://cli.github.com/manual/gh_release_create)、[Actions 安全配置](https://docs.github.com/en/actions/how-tos/security-for-github-actions/security-guides/security-hardening-for-github-actions)
- [Sparkle 发布与签名说明](https://sparkle-project.org/documentation/publishing/)、[Sparkle 2.10.0 包定义](https://github.com/sparkle-project/Sparkle/blob/2.10.0/Package.swift)
