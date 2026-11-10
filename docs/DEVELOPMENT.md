# 开发指南

Menu Tidy 使用 Swift 6、SwiftUI、AppKit 和 Swift Package Manager，自更新依赖固定为 Sparkle 2.10.0。应用目标声明 macOS 13 起可部署；声明的最低版本、CI 构建平台与真实交互验收是不同范围，请分别查看配置和[验收记录](README.md#验收记录)。

## 环境准备

在 macOS 上准备以下工具：

- Xcode 或 Command Line Tools，以及支持 Swift 6 的工具链、macOS SDK。
- Git、Bash 和 Python 3.11 或更新版本。
- `pre-commit`：运行提交门禁及安装 Git hooks。
- `git-cliff`：根据提交记录生成变更日志。

可先检查系统选中的开发工具：

```sh
xcode-select -p
xcrun swift --version
python3 --version
pre-commit --version
git-cliff --version
```

克隆后运行：

```sh
git clone https://github.com/cyruss648/menu-tidy.git
cd menu-tidy
./scripts/dev-setup.sh
```

`dev-setup.sh` 检查依赖和仓库配置，安装 `pre-commit`、`pre-push`、`commit-msg` hooks。它不安装系统软件，也不创建签名证书；已有自定义 hooks 会受到保护。遇到冲突应先阅读提示、保留既有内容，不要直接覆盖。

## 项目级 Codex skill

发布与本地安装流程保存在仓库的 [.agents/skills/menu-tidy-release-verify/SKILL.md](../.agents/skills/menu-tidy-release-verify/SKILL.md)，随项目提交和维护，无需安装到用户级 skill 目录。可在本项目中显式使用 `$menu-tidy-release-verify`，并说明要执行提交、推送、发布或本地安装中的哪些操作；流程会分别核验这些步骤。

## 日常检查

```sh
# 快速静态检查
./scripts/check.sh

# 指定文件的通用规则；本地化仍交叉检查完整源码与资源
./scripts/check.sh --static -- README.md Sources/MenuTidy/MenuTidyModel.swift

# Swift 编译与测试，编译警告视为错误
./scripts/check.sh --swift

# 提交前的完整检查
./scripts/check.sh --full
```

纯逻辑测试位于 `Tests/MenuTidyCoreTests/`；应用层集成测试位于 `Tests/MenuTidyAppTests/`，直接加载真实模型并执行分类与计时流程，使用隔离偏好和替代系统接口，覆盖旧数据加载、自动连接、确认、离线重建、忙碌结束后的自动收起，以及启动 30 秒后的待处理应用。启动补偿默认开启，复用维护计时器和“应用全部待处理”的串行队列；先刷新当前图标，忙碌时顺延，每次启动只尝试一次，扫描或应用失败不持续重试。安装脚本测试在临时目录中验证整包替换、旧资源移除和失败回滚。它们不申请辅助功能权限、不操作用户菜单栏，也不能证明第三方图标真实隐藏、系统快捷键或鼠标拖动生效。相关行为需要在已授权的应用包中做实机验收。

提交信息使用 Conventional Commits，例如：

```text
feat: add a menu item filter
fix: preserve pending rules after an interrupted move
docs: clarify system overflow limitations
```

提交前核对 `git diff` 与 `git diff --cached`。应用包、构建目录、本地签名私钥、钥匙串、授权数据及个人日志不应加入仓库。

## 本地化与外观状态

应用自己生成的提示、进度、警告、错误和行详情使用 `MenuTidyCore.LocalizedMessage` 保存静态键和参数，在视图或 AppKit 展示边界调用 `AppPreferences.localized`。例如：

```swift
let notice = LocalizedMessage("正在检查 \(index)/\(total)：\(item.name)")
let failure = LocalizedMessage("位置恢复尚未完成：\(error.localizedMessage)")
```

`LocalizedMessage` 只接收字面量及插值，不提供从任意运行时 `String` 构造翻译键的入口。插值的字符串作为原始数据保留，嵌套消息和应用自己的 `LocalizedMessageError` 保留各自的键。应用名称、路径、系统或第三方错误等外部数据不会进行替换或猜测翻译；需要直接展示外部文本时显式使用 `.verbatim(value)`。核心类型不读取 `UserDefaults` 或语言 bundle。

模型中不要保存 `copy(...)` 或 `.localizedDescription` 已渲染的应用文案，否则切换语言后旧消息不会更新。现有 printf 文案的键限为 `StaticString`；转发可变参数必须使用 `localizedFormat(key, arguments: arguments)`。新动态消息优先使用 `LocalizedMessage`，不依赖 printf 的不安全参数类型。

`python3 scripts/localization.py` 检查整个 `Sources/` 和 `Resources/en.lproj/Localizable.strings`，拒绝未包装的中文字面量、缺少英文键、重复键、空值、残留中文、格式参数数量/编号/类型不匹配，以及英文离线更新记录缺少版本。检查器识别注释、转义、普通/raw/多行字符串和嵌套插值；系统 AX 标签匹配只按精确文件与值保留两个例外。它是源码词法回归检查，不替代 Swift 类型检查或人工翻译质量审核。

这些检查进入 pre-commit、pre-push、完整 CI、正式打包和 UI Preview 构建。即使 pre-commit 只传入部分文件，本地化仍检查完整关系，避免删除一个翻译时漏掉未改动的使用方。英文发布历史为对应所有版本的离线摘要，原始完整验证记录继续保留在仓库 `CHANGELOG.md`。

外观和语言变化应由现有视图观察 `AppPreferences` 原地更新。不要为了刷新主题重建 `NSHostingView` 或设置与主题/语言绑定的 `.id`；这会重置滚动位置、弹层与局部状态。应用集成回归使用真实 `NSWindow`/`NSHostingView` 检查滚动容器、偏移和页面状态，并验证截图中的动态消息无需重新扫描即可切换语言；这些测试仍不等同于正式安装包的人工视觉验收。

## 构建与本地运行

```sh
./scripts/build.sh debug
./scripts/build.sh release
```

输出为 `dist/Menu Tidy.app`。脚本使用当前工具链的原生架构；构建结果不是 Universal Binary。调试启动应运行应用包，避免将裸 Swift 可执行文件的权限身份与正式安装副本混淆。

```sh
open "dist/Menu Tidy.app"
```

持续调试系统授权时，建议使用稳定安装位置。先从应用菜单退出已有实例，再安装：

```sh
./scripts/install.sh
open "/Applications/Menu Tidy.app"
```

默认安装到 `/Applications/Menu Tidy.app`。使用自定义目录时，显式指定绝对路径：

```sh
MENU_TIDY_INSTALL_DIR="$HOME/Applications" ./scripts/install.sh
```

安装脚本构建 release 包，复核应用已退出，在安装目录所在文件系统的全新临时目录复制并验证签名，再备份并整体替换已有安装。替换或最终校验失败时恢复原应用，避免合并目录残留已删除的旧资源；不可写时停止，不自动提权或改换目录。辅助功能授权必须由用户在系统设置确认。

## 签名与授权

普通构建优先使用明确指定的签名身份，其次使用已初始化的本地开发身份；没有可用身份时使用明确提示的 ad hoc 临时签名。已配置身份签名失败会停止，不静默降级。

如果需要跨多次本机构建保留同一身份，请阅读[本地签名说明](LOCAL-SIGNING.md)，再显式初始化：

```sh
./scripts/init-local-signing.sh --create
```

也可使用本机已有身份：

```sh
CODE_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)' ./scripts/build.sh release
```

为了测试临时签名产物，可显式设置：

```sh
CODE_SIGN_IDENTITY=- ./scripts/build.sh release
```

签名验证、辅助功能授权和 Apple 公证是不同事项。固定本地身份便于本机调试，不等同于 Developer ID 分发或公证。不要把本地开发私钥或钥匙串上传到公开仓库；公开发布包的签名与公证状态应在 Release 中说明。

## 自更新开发

应用通过共享的 `UpdateController` 接入 Sparkle 标准更新界面，设置与菜单不能各自创建更新器。默认自动检查，自动下载并在退出时安装默认关闭；后续偏好交由 Sparkle 持久化，不在每次启动时重置。演示和诊断入口不启动更新服务。

SwiftPM 负责解析固定版本，应用打包还必须嵌入 `Sparkle.framework`，保留符号链接与可执行权限，并配置 `@executable_path/../Frameworks`。签名脚本按内部 helper、framework、外层应用的顺序签名；只编译可执行文件不能替代应用包验证。

`Resources/Info.plist` 保存更新公钥与签名要求，最终应用包使用与自身架构、版本通道相符的 feed。归档和 feed 使用独立于 macOS 代码签名证书的 EdDSA 密钥。签名密钥不属于普通 push 或 PR 构建输入；缺少发布密钥应停止签名流程，不生成无签名更新作为替代。

更新安装须经过应用原有退出流程，不能绕过当前分类操作、未结束排序事务或退出恢复。开发验证应覆盖更新偏好重启保留、操作期间等待、取消退出、下载或签名失败，以及旧应用真正被替换并重新启动后的状态。构建和签名自检不能证明这条升级链已成功。

历史 build 28 的隔离 bundle 更新试验记录仍保留在[应用内更新说明](AUTO-UPDATE.md)，其范围仅为当时的签名升级、安装重启与测试偏好保留。当前源码版本以 `Resources/Info.plist` 为准，公开发布与更新 feed 以实际 GitHub Release 和 Actions 结果为准；不要将历史本机安装记录作为当前状态。每个新版本均需单独核对忙碌清理、失败恢复及发布产物。

## 变更日志

`changelog.sh` 将预览输出到标准输出，不覆盖已有手写首发说明：

```sh
./scripts/changelog.sh --unreleased
./scripts/changelog.sh --latest
# 对应标签创建后，可查看该版本的提交摘要
./scripts/changelog.sh --tag v0.5.0
```

应用版本和构建号的唯一来源是 `Resources/Info.plist`，当前源码为 `0.7.7 / build 83`，对应标签为 `v0.7.7`。版本号、构建号、tag 与 Release 标题需要保持一致，构建号必须递增；源码准备完成不表示公开发布已经完成。准备发布时，应复核面向用户的变化、已知限制和升级说明，不把纯内部诊断记录直接作为 Release 说明。

## 打包与发布入口

本地打包从 `Resources/Info.plist` 读取版本，不接受额外参数：

```sh
./scripts/package.sh
```

脚本自动构建 release 应用、核对原生架构和签名，并在 `dist/` 生成：

- `Menu-Tidy-<版本>-macos-<架构>.zip`，架构为 `arm64` 或 `x86_64`。
- 对应 `.zip.sha256` 校验文件。
- 对应 `.zip.metadata.json`，记录版本、构建号、架构、提交、工作区状态、二进制哈希及签名等信息。

这是当前机器的原生包；单次本地打包不会生成另一架构或 Universal Binary。下载或解压前，可在产物所在目录验证校验文件，例如 Apple Silicon 0.5.0 包：

```sh
shasum -a 256 -c Menu-Tidy-0.5.0-macos-arm64.zip.sha256
```

维护者发布还需要已登录的 GitHub CLI（`gh`）、仓库推送权限及经授权配置的代码签名和 Sparkle 签名 secrets。以下是完成验收后的流程示例，当前未通过的验收和未配置的密钥不能用推送标签绕过。先更新 Info.plist 的版本与构建号、准备 `CHANGELOG.md` 对应版本说明，将更改提交并推送 `main`，等待该提交的 CI 通过，再执行：

```sh
# 只预览发布说明，不推送
python3 scripts/release-notes.py v0.5.0

# 执行本地完整检查，创建并推送 v0.5.0 注解标签
./scripts/release.sh 0.5.0
```

`release.sh` 检查资源版本、GitHub 登录、干净工作区、当前分支为 `main` 且 HEAD 等于 `origin/main`，然后运行 `check.sh --full`。成功后推送标签，触发 GitHub Actions 双架构构建、归档签名、Release 和签名 feed 发布。不带预发布后缀的版本进入 `stable`，带后缀的版本进入 `preview`；例如 `0.5.0` 属于 stable，不因仍在开发而自动成为 prerelease。脚本会实际推送，不能用作无副作用的预览；既有标签不覆盖。

当前公开产物使用项目专用自签名证书，**不是 Apple Developer ID，也未经过 Apple 公证**。这是与本地开发身份分开的发布配置。CI 平台、签名材料管理及发布流程详见[发布指南](RELEASING.md)，不要把仓库自动构建通过等同于 macOS 13、Intel 或多显示器交互已实测。

## 实现结构

| 位置 | 职责 |
| --- | --- |
| `Sources/MenuTidy/SettingsView.swift` | 图标列表、分类草稿、权限反馈和偏好设置 |
| `Sources/MenuTidy/MenuTidyModel.swift` | 权限状态、扫描与移动协调、验证和规则持久化 |
| `Sources/MenuTidy/MenuBarAccessibility.swift` | 独立 actor 中的 AX 元素、几何判断、原生拖动和清理 |
| `Sources/MenuTidy/StatusBarController.swift` | 菜单栏控制项、两个分组边界及显示状态 |
| `Sources/MenuTidy/Main.swift` | 应用生命周期、设置窗口和重复打开恢复 |
| `Sources/MenuTidy/UpdateController.swift` | 共享更新器、更新偏好、检查状态与安装等待 |
| `Sources/MenuTidy/UpdateSettingsView.swift` | 更新设置与反馈 |
| `Sources/MenuTidyCore/` | 状态机、自动收起、布局、规则和稳定身份等纯逻辑 |
| `Tests/MenuTidyCoreTests/` | 无系统权限依赖的核心测试 |
| `Tests/MenuTidyAppTests/` | 隔离系统接口与偏好的真实模型集成测试 |
| `Resources/` | Info.plist 与应用图标 |
| `scripts/` | 检查、构建、安装、签名和发布工具 |

更新发布使用 `scripts/fetch-sparkle-tools.py` 获取固定官方工具，`scripts/generate-update-feed.py` 签名和校验归档、生成签名 feed。工具不会自行推送分支或创建 Release；发布由工作流协调，完整命令与权限边界见[发布指南](RELEASING.md)。

修改分组逻辑时，应保持以下边界：

- 列表选择是草稿；接受规则前必须取得可信位置验证，未知坐标不算成功。
- 持久身份依赖 bundle identifier 与唯一 AXIdentifier，不以显示名称猜测目标。
- 不移动受保护系统项目；始终保留恢复入口和用户预先打开的系统 overflow 状态。
- 取消、失败与退出路径释放本次合成输入；不要将成功路径验收替代异常路径测试。
- 诊断日志避免记录外部应用名称、标识、菜单内容或其他用户数据。

## 实机验收与参考

每次涉及 AX、菜单栏布局、事件投递、权限或签名的修改，应补充独立的实机验证记录，注明系统、架构、显示器、测试目标、恢复状态和未覆盖场景。对历史报告的补充应保留原有事实，不将后续修复写成旧版本已经通过。

项目采用独立实现。API 与实验策略参考：

- [Apple：AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- [Apple：AXUIElementCopyAttributeValue](https://developer.apple.com/documentation/applicationservices/1462085-axuielementcopyattributevalue)
- [Apple：NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [Apple：NSWorkspace.icon(forFile:)](https://developer.apple.com/documentation/appkit/nsworkspace/icon%28forfile%3A%29)
- [Ice：macOS 27 兼容实验 PR #980](https://github.com/jordanbaird/Ice/pull/980)

上游实验结果不代表本项目通过；macOS 27 的已知显示容量限制仍需在用户说明和 Release 中明确保留。
