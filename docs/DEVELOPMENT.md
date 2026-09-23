# 开发指南

Menu Tidy 使用 Swift 6、SwiftUI、AppKit 和 Swift Package Manager。应用目标声明 macOS 13 起可部署；声明的最低版本、CI 构建平台与真实交互验收是不同范围，请分别查看配置和[验收记录](README.md#验收记录)。

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

## 日常检查

```sh
# 快速静态检查
./scripts/check.sh

# 只检查指定文件的静态规则
./scripts/check.sh --static -- README.md Sources/MenuTidy/MenuTidyModel.swift

# Swift 编译与测试，编译警告视为错误
./scripts/check.sh --swift

# 提交前的完整检查
./scripts/check.sh --full
```

纯逻辑测试位于 `Tests/MenuTidyCoreTests/`。它们不申请辅助功能权限、不操作用户菜单栏，也不能证明第三方图标真实隐藏、系统快捷键或鼠标拖动生效。相关行为需要在已授权的应用包中做实机验收。

提交信息使用 Conventional Commits，例如：

```text
feat: add a menu item filter
fix: preserve pending rules after an interrupted move
docs: clarify system overflow limitations
```

提交前核对 `git diff` 与 `git diff --cached`。应用包、构建目录、本地签名私钥、钥匙串、授权数据及个人日志不应加入仓库。

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

安装脚本构建 release 包、检查目标应用身份并备份已有安装；不可写时停止，不自动提权或改换目录。辅助功能授权必须由用户在系统设置确认。

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

## 变更日志

`changelog.sh` 将预览输出到标准输出，不覆盖已有手写首发说明：

```sh
./scripts/changelog.sh --unreleased
./scripts/changelog.sh --latest
./scripts/changelog.sh --tag v0.3.1
```

版本号、构建号、tag 与 Release 标题需要保持一致。准备发布时，应复核面向用户的变化、已知限制和升级说明，不把纯内部诊断记录直接作为 Release 说明。

## 打包与发布入口

本地打包从 `Resources/Info.plist` 读取版本，不接受额外参数：

```sh
./scripts/package.sh
```

脚本自动构建 release 应用、核对原生架构和签名，并在 `dist/` 生成：

- `Menu-Tidy-<版本>-macos-<架构>.zip`，架构为 `arm64` 或 `x86_64`。
- 对应 `.zip.sha256` 校验文件。
- 对应 `.zip.metadata.json`，记录版本、构建号、架构、提交、工作区状态、二进制哈希及签名等信息。

这是当前机器的原生包；单次本地打包不会生成另一架构或 Universal Binary。下载或解压前，可在产物所在目录验证校验文件，例如 Apple Silicon 0.3.1 包：

```sh
shasum -a 256 -c Menu-Tidy-0.3.1-macos-arm64.zip.sha256
```

维护者发布还需要已登录的 GitHub CLI（`gh`）和仓库推送权限。先更新 Info.plist 的版本与构建号、准备 `CHANGELOG.md` 对应版本说明，将更改提交并推送 `main`，等待该提交的 CI 通过，再执行：

```sh
# 只预览发布说明，不推送
python3 scripts/release-notes.py v0.3.1

# 执行本地完整检查，创建并推送 v0.3.1 注解标签
./scripts/release.sh 0.3.1
```

`release.sh` 检查资源版本、GitHub 登录、干净工作区、当前分支为 `main` 且 HEAD 等于 `origin/main`，然后运行 `check.sh --full`。成功后推送标签，触发 GitHub Actions 双架构构建及预览版发布。它会实际推送，不能用作无副作用的预览；既有标签不覆盖。

当前公开产物使用项目专用自签名证书，**不是 Apple Developer ID，也未经过 Apple 公证**。这是与本地开发身份分开的发布配置。CI 平台、签名材料管理及发布流程详见[发布指南](RELEASING.md)，不要把仓库自动构建通过等同于 macOS 13、Intel 或多显示器交互已实测。

## 实现结构

| 位置 | 职责 |
| --- | --- |
| `Sources/MenuTidy/SettingsView.swift` | 图标列表、分类草稿、权限反馈和偏好设置 |
| `Sources/MenuTidy/MenuTidyModel.swift` | 权限状态、扫描与移动协调、验证和规则持久化 |
| `Sources/MenuTidy/MenuBarAccessibility.swift` | 独立 actor 中的 AX 元素、几何判断、原生拖动和清理 |
| `Sources/MenuTidy/StatusBarController.swift` | 菜单栏控制项、两个分组边界及显示状态 |
| `Sources/MenuTidy/Main.swift` | 应用生命周期、设置窗口和重复打开恢复 |
| `Sources/MenuTidyCore/` | 状态机、自动收起、布局、规则和稳定身份等纯逻辑 |
| `Tests/MenuTidyCoreTests/` | 无系统权限依赖的核心测试 |
| `Resources/` | Info.plist 与应用图标 |
| `scripts/` | 检查、构建、安装、签名和发布工具 |

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
