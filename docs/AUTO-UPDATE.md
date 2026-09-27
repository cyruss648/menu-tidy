# 应用内更新

Menu Tidy 使用固定版本 **Sparkle 2.10.0** 提供应用内检查、下载、签名验证和安装更新。0.5.0 包含此功能；下方更新 GUI 的历史交互记录对应 build 27。独立 bundle 的签名更新包已完成检查、安装、重新启动和设置保留验证；它不代表主应用的每个线上升级路径均已验收。`SPARKLE_PRIVATE_KEY` 已经用户明确授权上传，GitHub 发布成功后才推进签名 feed。feed 尚未生成或网络失败时可能返回错误，不能解释为“已经是最新版”。

## 用户如何更新

在设置的更新区域或菜单中选择 **检查更新…**。两个入口共用一个更新器，显示当前版本、最近检查时间、进度及错误，不会并行启动两次更新。

| 选项 | 默认值 | 行为 |
| --- | --- | --- |
| 自动检查更新 | 开启 | 后台检查当前安装包所对应的更新通道 |
| 自动下载并在退出时安装 | 关闭 | 自动检查开启时可启用；允许 Sparkle 下载更新，并在正常退出时安装 |
| 手动检查更新 | 可用时由用户触发 | 使用标准更新界面查看版本、下载和安装 |

用户修改后的选择会保留，重启应用不会将它们重置成默认值。正在整理、应用分类、刷新、恢复排序或调用图标动作时，检查更新会暂不可用或提示稍后再试；已经准备好的安装会等待当前操作，并继续经过应用原有退出流程。

关闭自动检查会暂停自动检查和下载，手动检查仍可用；重新开启自动检查时，Sparkle 会恢复此前保存的自动下载选择。关闭检查不能当作取消已下载并安排退出安装的既有任务，需要在更新界面核对当前任务状态。

旧 build 24 没有更新器，不能自行获得这一功能。首次升级到包含更新器的版本需要安装与 Mac 架构对应的包，退出旧实例后替换 `/Applications/Menu Tidy.app`。公开安装包与签名 feed 以对应 Release 和 Actions 结果为准；安装验收单独记录，不能用本地候选替代。只有运行已包含更新器的版本，才能使用后续应用内更新。

如果更新失败，保留错误提示并核对网络、安装位置及 Release 状态；仍可从[项目 Releases](https://github.com/cyruss648/menu-tidy/releases)下载对应架构安装包。更新签名不替代首次打开时的 macOS 安全检查，不应关闭系统安全保护来处理失败。

## 版本通道和架构

通道由应用版本中的语义化预发布后缀决定，不由 README 中的“开发版”或“预览版”字样决定：

| 版本例子 | 通道 | GitHub Release |
| --- | --- | --- |
| `0.5.0` | `stable` | 稳定版，可更新 Latest |
| `0.5.0-beta.1` | `preview` | Prerelease，不覆盖稳定版 Latest |

每个安装包同时固定自身的架构和通道。当前没有界面内切换通道或跨架构迁移；需要改换时，应明确下载安装对应包。Apple Silicon 与 Intel 使用独立 zip，当前不提供 Universal 包。

公开 feed 地址约定如下，地址存在不代表其内容已经发布：

| 通道 | Apple Silicon | Intel |
| --- | --- | --- |
| stable | [appcast-arm64.xml](https://raw.githubusercontent.com/cyruss648/menu-tidy/updates/stable/appcast-arm64.xml) | [appcast-x86_64.xml](https://raw.githubusercontent.com/cyruss648/menu-tidy/updates/stable/appcast-x86_64.xml) |
| preview | [appcast-arm64.xml](https://raw.githubusercontent.com/cyruss648/menu-tidy/updates/preview/appcast-arm64.xml) | [appcast-x86_64.xml](https://raw.githubusercontent.com/cyruss648/menu-tidy/updates/preview/appcast-x86_64.xml) |

feed 存在仓库的 `updates` 分支，更新包来自 GitHub Release。每份 feed 当前保留该通道、该架构的最新一项。`CFBundleShortVersionString` 用于显示语义版本，正整数 `CFBundleVersion` 用于更新先后判断；发布工具要求构建号高于两个通道的已发布构建，同一通道的语义版本也须递增。

## 下载、数据和签名

正常更新会通过 HTTPS 访问 GitHub 上的 feed 和更新归档。更新器不上传菜单栏图标快照、分类规则或菜单内容，也关闭 Sparkle 可选的系统配置报告。更新偏好与最近检查状态由 Sparkle 按应用保存；下载的更新包由 Sparkle 管理，与仅在内存中保留的菜单栏图标快照不同。演示及诊断启动不创建更新器，不访问更新 feed。

本项目分别处理三件事：

| 机制 | 作用 | 当前边界 |
| --- | --- | --- |
| macOS 代码签名 | 校验应用与内部可执行组件的签名身份和完整性 | 发布使用项目专用自签名身份 |
| Sparkle EdDSA 签名 | 用应用内置公钥校验更新归档和 feed | 与 macOS 签名证书独立，私钥只用于授权的发布流程 |
| Apple Developer ID 与公证 | Apple 分发身份和公证流程 | 当前未提供，不能由前两者替代 |

应用要求 `SURequireSignedFeed=true` 和 `SUVerifyUpdateBeforeExtraction=true`：先验证更新信息，归档解压前再验证归档签名。公钥保存在 `SUPublicEDKey`，可以随源码和应用公开；私钥不得进入 Git、文档、命令行参数或日志。签名 feed 的说明嵌入 XML，修改任何已签名内容都必须重新签名。[Sparkle 官方签名配置](https://sparkle-project.org/documentation/#signing-feeds-optional)

代码签名证书和更新密钥需要长期保持连续性。当前自签名方案不能假定具有 Developer ID 支持的密钥轮换恢复能力；丢失 EdDSA 私钥可能需要用户手动安装新版本。更换密钥前必须另行设计迁移并验证，不能直接替换 Info.plist 的公钥继续发布。[Sparkle 密钥轮换约束](https://sparkle-project.org/documentation/#rotating-signing-keys)

## SwiftPM 应用包集成

| 位置 | 职责 |
| --- | --- |
| `Package.swift` | 固定 Sparkle `exact: "2.10.0"`，链接 framework 并设置运行时搜索路径 |
| `Resources/Info.plist` | 应用版本、更新公钥、默认偏好及签名要求 |
| `Sources/MenuTidy/UpdateController.swift` | 唯一共享更新器、用户偏好、状态与安装等待 |
| `Sources/MenuTidy/UpdateSettingsView.swift` | 更新设置及反馈；菜单复用相同 controller |
| `scripts/build.sh`、`scripts/prepare-update-bundle.py`、`scripts/local-signing.py` | 嵌入 framework、配置最终 feed、从内到外签名应用包 |
| `scripts/generate-update-feed.py` | 签名归档，验证产物和旧 feed，生成签名 XML |
| `.github/workflows/ci.yml` | 双架构验证、发布完整 Release，再推送 feed |

非 Xcode 的打包流程仍必须将 `Sparkle.framework` 嵌入 `Contents/Frameworks`，保留 framework 的符号链接和可执行权限；主程序使用 `@executable_path/../Frameworks` 运行时搜索路径。[Sparkle 集成说明](https://sparkle-project.org/documentation/)

嵌套签名顺序为内部 XPC 服务、Autoupdate、Updater.app、framework，最后外层 Menu Tidy.app。内部组件保留各自身份和必要 entitlement，使用当前配置的代码签名身份处理；不能把外层应用的 designated requirement 原样套到所有 helper，也不能用递归签名替代明确的组件顺序。[Sparkle 组件签名说明](https://sparkle-project.org/documentation/sandboxing/#code-signing)

最终归档产生后再进行 EdDSA 签名。归档必须保留应用包结构，签名后不能重新压缩或修改内容。本项目继续使用 `ditto` 打包，并将原生架构、版本、提交、文件摘要和代码签名要求记录到 metadata。[Sparkle 归档与发布说明](https://sparkle-project.org/documentation/publishing/)

## 安装生命周期

`UpdateController` 使用 `SPUStandardUpdaterController`，并在当前菜单栏操作未结束时推迟重新启动。该委托检查只是提前等待；退出时仍由 `applicationShouldTerminate` 处理事务清理与恢复，避免检查结束后刚好开始新操作的竞态。正常更新不能强制结束应用或绕过尚未完成的排序事务。

开启自动下载后，Sparkle 可安排退出时安装；`willInstallUpdateOnQuit` 返回值不应被误解为通用的安装否决开关。重新启动等待和最终退出保护需要一起保留。[Sparkle 更新委托 API](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)

## 签名工具接口

完整发布以前置验收和授权为条件，操作顺序见[发布指南](RELEASING.md)。以下是工具接口示例，版本、`FULL_COMMIT_SHA` 和 `/path/to/` 路径需要替换成对应实际值；不要将私钥直接写入命令。普通本地打包仍只生成 zip、SHA-256 和 metadata，签名阶段另生成 `.zip.eddsa.json`。

```sh
# 下载固定版本官方工具并核对归档 SHA-256
python3 scripts/fetch-sparkle-tools.py --output .build/sparkle-tools

# 签名单个架构的最终归档；需要已安全提供 SPARKLE_PRIVATE_KEY
python3 scripts/generate-update-feed.py sign \
  --artifacts dist --arch arm64 --tag v0.5.0 --commit FULL_COMMIT_SHA \
  --sign-tool .build/sparkle-tools/bin/sign_update

# 全部双架构产物校验通过后，在本地准备本次通道的两份签名 feed
python3 scripts/generate-update-feed.py generate \
  --artifacts artifacts --tag v0.5.0 --commit FULL_COMMIT_SHA \
  --sign-tool .build/sparkle-tools/bin/sign_update \
  --feeds /path/to/updates-branch --notes /path/to/release-notes.md
```

默认读取 `Resources/Info.plist`，测试配置可用 `--info` 显式指定。`SPARKLE_PRIVATE_KEY` 仅从环境读取，通过标准输入交给官方 `sign_update`；工具再使用 Info 中的公钥独立验证结果。生成 feed 前，必须先将两个架构的 zip、checksum、metadata 和 EdDSA 记录放入同一产物目录，共八个文件；输入目录不能混有其他归档。

`--feeds` 指向当前 `updates` 分支的检出目录，首次发布可使用新建空目录。已有 feed 会先验签并检查通道、架构、版本与构建号；读取失败或签名不符不作为“首次发布”处理。两个新 feed 在临时位置准备并验证后才写入目标目录。工具本身不创建 GitHub Release、不推送分支。

维护者需要三项 secrets：`MACOS_SIGNING_P12_BASE64`、`MACOS_SIGNING_PASSWORD` 和 `SPARKLE_PRIVATE_KEY`。普通 push、PR 不使用它们；标签发布或明确开启的手动签名验证才读取。用户明确授权后，`SPARKLE_PRIVATE_KEY` 已通过标准输入成功保存到 `cyruss648/menu-tidy` 的 GitHub Actions Secrets，更新时间为 `2026-09-24T19:31:34Z`。配置成功不等于新发布流水线已运行通过，也不解除实机验收的发布前置条件。

首次建立独立更新密钥可显式运行 `swift scripts/init-update-signing.swift --create`。脚本仅在当前用户的 Application Support 目录保存受权限保护的 32 字节 Ed25519 seed，输出公钥和存储位置，不输出私钥；已有密钥会复用，不自动替换。普通构建不会创建密钥。项目现有公钥必须与发布私钥保持对应，新维护者不能生成自己的密钥后直接覆盖它。私钥应安全备份，并仅在明确授权后通过标准输入配置仓库 Secret。

发布工作流先验证八个附件，准备两个签名 feed，再创建并校验 draft Release 的附件。Release 公开后才将对应通道的 feed 推送到 `updates`，不 force push，也不覆盖已有 Release。若最后推送失败，应用可能继续看到旧 feed，应检查并恢复该步骤，而不是改写已有标签或取消签名检查。

## 本地验收记录

2026-09-25，0.5.0 / build 26 在开发机器上取得以下证据：

| 检查 | 结果 | 证明范围 |
| --- | --- | --- |
| release 应用包签名 | 使用原有固定证书，`codesign --verify --deep --strict` 通过 | 包内嵌套代码签名可校验，不代表 Apple 公证 |
| framework 加载 | 通过命令行拒绝型探针确认 dyld 加载应用包内的 `Sparkle.framework` | 动态链接与打包路径正确；未触发菜单栏输入或更新安装 |
| 自动化测试 | 171 项 Swift 测试、66 项 Python 测试通过 | 对应逻辑与构建、签名、feed 工具检查；不是桌面交互验收 |
| 真实 zip 与 feed 验签 | 官方 `sign_update` 生成签名，独立 CryptoKit 校验正常内容通过；篡改 zip、篡改 feed 和错误公钥均拒绝 | 本地签名与验证链有效，尚未证明远端发布内容 |
| 真实 Sparkle 检查器 | 独立临时应用包调用 `SPUUpdater.checkForUpdateInformation()`，通过仅本机 loopback HTTP 识别签名 feed 中的 build 26；篡改 feed 返回 `SUSparkleErrorDomain 1000` | 实际 Sparkle 能解析和验证 feed；未下载、安装或弹出更新界面，不等于 GUI 升级通过 |
| 偏好跨进程保留 | 实际 `SPUUpdater` 默认检查开启、自动下载关闭；启用下载后重启保留。关闭检查后有效自动下载也关闭，手动检查仍可用；重启保持，再开启检查恢复此前下载选择 | 证明 Sparkle 的偏好持久化及两项设置的依赖关系，未验证取消已排定的安装 |

上述 build 26 验证阶段，公钥已写入 Info.plist，私钥仅保存在本机应用支持目录，文件权限为 `0600`，当时尚未获准上传。此后用户已明确授权，并完成 GitHub Secret 配置，见下方记录；远端签名流水线仍需在实际运行后另行确认。本地受控 HTTP 仅用于上述检查器测试；正式 feed 仍使用 HTTPS。

### build 27：调度与取消回归

只读复核发现：Sparkle 在委托拒绝检查时也会更新最近检查时间，直接拒绝启动扫描期间的自动检查会把下次检查推迟一个周期。现在先等待初始扫描结束再启动更新器；运行期间因繁忙而延后的自动请求合并成一次，在原会话结束且空闲后异步补查。关闭自动检查清除该请求，手动请求不转成自动重试。下载取消使用框架的专用回调更新状态，不再残留“正在下载”。

新增 8 项调度 XCTest，完整 Swift 测试共 179 项通过；build 27 发布证书签名构建和嵌套签名验证通过。准备独立 bundle identifier 的两版验收包时曾因锁屏暂停，彼时主安装仍为 build 24。用户随后解锁，现已将本地 build 27 安装到 `/Applications/Menu Tidy.app`，并完成下方隔离更新包的桌面验证；未提交、推送或创建发布标签。

发布脚本同时统一了严格版本校验，并在推标签之前读取远端已签名更新信息，验证版本和构建号递增。新增 11 项只读预检回归后，全部 Python 测试共 77 项通过，源码门禁通过；当前仓库首次发布更新 feed 的只读预检通过，没有创建或推送标签。这不替代前述桌面验收。

### 2026-09-25：隔离应用的实际安装与重启

用户回复「已解锁并授权」后，更新专用私钥经标准输入上传到仓库的 Actions Secret；记录的更新时间为 `2026-09-24T19:31:34Z`（北京时间 2026-09-25 03:31:34）。只记录 Secret 名称和状态，不将私钥内容写入仓库、命令参数或验证日志。

使用 `.local/update-acceptance/installed/Menu Tidy Update Acceptance.app` 进行图形界面安装链验证。该应用具有独立 bundle identifier，使用与主应用相同的 Sparkle 及嵌套辅助组件，独立保留测试偏好，不覆盖主应用。实际操作和结果如下：

| 检查 | 实际结果 | 证明范围 |
| --- | --- | --- |
| 检查更新与下载 | 从 `1.0.0-test.1 / build 1` 通过界面点击检查更新、安装 | 实际 Sparkle GUI 能发现并下载受控签名更新 |
| 安装并重新启动 | 点击「安装并重启」后，安装副本变为 `1.0.0-test.2 / build 2` | 实际退出、应用替换和重启链通过，不是仅准备安装包 |
| 安装后的二进制 | `binaryMatchesTarget=true` | 安装后的可执行文件与目标版本相同 |
| 升级后代码签名 | `codesign --verify --deep --strict` 通过 | 外层应用及嵌套组件签名完整，不代表 Apple 公证 |
| 测试偏好保留 | sentinel `preserve-this-value-through-upgrade` 保留 | 独立测试应用的既有偏好没有因替换而丢失 |
| 再次检查 | 显示已经是最新版 | 同一测试 feed 的目标 build 已安装后，不重复提示该升级 |
| 主应用隔离 | `/Applications/Menu Tidy.app` 仍为 build 27 | 本次安装链未将主应用替换成测试 bundle |

**本节仅确认隔离 bundle 的安装链。** 它不验证主应用繁忙时的等待、排序事务清理、退出取消、主应用分类草稿与权限保留，也不验证线上 HTTPS feed、GitHub 附件下载或最终发布物安装。正式双架构发布尚未执行。主应用 build 27 的 Bob 自动分组实测仍失败，详细结果见[后台验证记录](BACKGROUND-INPUT.md#2026-09-25-build-27系统溢出动作实际验证)。

### build 27：主应用更新设置的实际交互

已在 `/Applications/Menu Tidy.app` 的 build 27 界面验证设置状态和手动检查入口：

| 操作 | 实际结果 | 证明范围 |
| --- | --- | --- |
| 自动检查从开切到关 | 自动下载显示关闭且禁用，「检查更新…」仍可点击 | 自动检查关闭不阻止用户手动检查 |
| 自动检查关闭后手动检查 | 实际发起请求，返回获取 feed 的错误 | 正式 feed 尚未发布时没有误报“已经是最新版”；不证明线上更新成功 |
| 恢复自动检查，再切换自动下载 | 自动下载关闭 → 开启 → 关闭均正确 | 两项设置可以操作，最终恢复原偏好：自动检查开启、自动下载关闭 |
| 设置页面滚动区域 | 本次界面只观察到一个设置滚动区和滚动条 | 当前页面没有出现嵌套滚动条；不扩大为所有窗口尺寸或页面的验证 |

隔离验收应用随后已退出，本机 `localhost:32251` 测试服务器已停止。该清理不表示测试文件或主应用用户数据已删除，也没有将测试 feed 配置为正式线上 feed。

## 验收要求和当前状态

隔离应用已取得真实升级、重新启动及测试偏好保留的通过证据；主应用与线上发布链仍未完成整体验收。不能把独立 bundle 的通过结论扩大为 Menu Tidy 的排序清理和发布物安装也已通过。发布前仍需验证：

- 使用最终主应用及发布来源，在包含更新器的旧安装与更高构建号安装之间完成发现、下载、验签、正常退出、替换和重新启动，确认实际安装版本；隔离应用已验证基础安装链，但不能替代此项。
- arm64 与 x86_64 各自只读取正确 feed，stable 与 preview 不串通道；同版本、较低构建号不造成反复提示或降级。
- 篡改 feed、更新归档或签名，公钥不匹配、网络失败及不存在的 feed 都显示失败，不误报已是最新版。
- 更新偏好重启后保留；自动下载默认关闭；演示与诊断入口无更新网络请求。
- 整理、应用分类、排序恢复与退出取消期间，安装等待及最终退出保护有效；原有草稿和恢复记录不因升级丢失。
- 在最终签名应用和实际安装路径验证内部 helper、权限、原有辅助功能及排序目录授权，分别记录 Intel、旧系统等未覆盖范围。

分组功能的实机验收也是本版本发布前置条件，不能因更新流程已接入而省略。当前版本、限制和验证进展以 [CHANGELOG](../CHANGELOG.md) 与对应实际验收记录为准。


### 2026-09-26 build 48 的设置与互斥回归

主应用本地安装包的设置页显示 0.5.0（48）。显式刷新图标期间，“检查更新”不可用；刷新结束后恢复可用。自动下载从关闭切到开启，再关闭自动检查时有效下载状态为关闭且控件禁用；重新开启自动检查后恢复此前下载选择。测试结束还原为自动检查开启、自动下载关闭。

退出恢复现在在首个异步等待前取得独立恢复 generation；旧任务结束不能解除该门闩，成功后一直保留至退出，失败后释放以便重试。该版本完整检查为 286 项 Swift、80 项 Python 测试；这不代表主应用已从公开 feed 升级。生产 feed 与 GitHub 产物安装仍须按最终发布后的实际结果记录。
