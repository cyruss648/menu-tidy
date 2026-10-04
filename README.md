<div align="center">

# Menu Tidy

为 macOS 菜单栏提供可验证的三态整理、独立托盘和可恢复操作。

[![macOS](https://img.shields.io/badge/macOS-13%2B-111111?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-FA7343?logo=swift&logoColor=white)](https://www.swift.org/)
[![CI](https://github.com/cyruss648/menu-tidy/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/cyruss648/menu-tidy/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/cyruss648/menu-tidy?display_name=tag&sort=semver)](https://github.com/cyruss648/menu-tidy/releases/latest)

[下载最新版本](https://github.com/cyruss648/menu-tidy/releases/latest) · [文档索引](docs/README.md) · [报告问题](https://github.com/cyruss648/menu-tidy/issues)

</div>

> [!IMPORTANT]
> Menu Tidy 通过 macOS 辅助功能、菜单栏显示设置和位置证据管理第三方图标。它不会把第三方 `NSStatusItem` 控件搬进自己的窗口，也不会发送全局模拟鼠标或键盘事件。不同 macOS 版本、显示器布局和应用的支持范围不同；界面只有在真实身份、位置和恢复状态得到确认后才会标记操作完成。

## 为什么使用 Menu Tidy

macOS 没有一个面向第三方应用的公开菜单栏统一管理 API。Menu Tidy 将菜单栏整理拆成三件事：保存用户意图、执行系统允许的操作、验证实际结果。这样可以在图标暂时离线、权限变化、AX 查询超时或应用不支持后台动作时保留选择和恢复记录，而不是把一次接口返回当成成功。

日常使用时，点击菜单栏箭头会打开一个独立的六列托盘。托盘优先使用最近一次确认的原始图标快照；没有可用快照时显示应用身份图标或名称。原始图像采集是可选增强，不是打开托盘的前提。

## 功能

- **三种显示方式**：常驻显示、收起后隐藏、始终隐藏。
- **即改即用**：修改单项选择后立即进入串行处理；顶部可统一应用待处理项或重试失败项。
- **独立托盘**：使用六列网格快速访问已发现的图标；搜索、筛选和临时显示全部集中在同一入口。
- **安全恢复**：操作前保存恢复意图，操作后重新读取并核对真实状态；未知结果继续显示为待确认。
- **离线记录**：应用暂时未运行时保留分类选择和草稿，重新发现并确认身份后再连接。
- **原生动作**：对支持的项目请求一次原生辅助功能动作；目标菜单或窗口未确认出现时不重复发送。
- **可选原始图像**：在获得屏幕录制权限后采集已确认的小区域图像；采集失败时使用应用图标回退。
- **自动收起与登录启动**：均可在设置中开启，默认关闭。
- **应用内更新**：使用 Sparkle 检查对应架构和更新通道；更新会等待当前整理或恢复操作结束。

### 三种显示方式

| 选择 | 原生菜单栏 | 独立托盘 |
| --- | --- | --- |
| **常驻显示** | 保持可见，仍受系统空间限制 | 不作为隐藏项展示 |
| **收起后隐藏** | 收起时隐藏 | 点击箭头时展示 |
| **始终隐藏** | 保持隐藏 | 普通打开不展示；“临时显示全部”时可见 |

macOS 27 使用按应用控制的原生显示开关；同一应用的多个图标可能共用一个系统选择。旧系统使用兼容路径。两条路径都要求逐项确认，保存选择本身不代表系统已经完成隐藏。

## 安装

### 下载发布包

从 [GitHub Releases](https://github.com/cyruss648/menu-tidy/releases/latest) 下载与 Mac 架构对应的压缩包：

- Apple Silicon：`arm64`
- Intel：`x86_64`

解压后将 `Menu Tidy.app` 拖入 `/Applications`，再从应用程序文件夹启动。发布包使用项目专用自签名证书，并非 Apple Developer ID，当前未公证；首次打开时请依据 macOS 的安全提示确认来源，不要关闭系统安全保护绕过提示。

### 从源码构建

项目使用 Swift 6、Swift Package Manager 和 Sparkle 2.10.0。完整构建流程见[开发指南](docs/DEVELOPMENT.md)。

## 快速开始

1. 退出 Barbee、Bartender、Ice 等其他菜单栏整理器，避免多个工具同时控制同一批图标。
2. 打开 Menu Tidy，在“权限与设置”中授予辅助功能权限。
3. macOS 27 另外选择并授权菜单栏显示设置文件；不需要完整磁盘访问。
4. 点击“刷新”，等待菜单栏图标完成读取。目标应用必须正在运行，离线记录不会伪造在线图标。
5. 在“托盘图标”页选择 **常驻显示 / 收起后隐藏 / 始终隐藏**。每次选择都会立即处理，并在行内保留处理中、待确认或失败原因。
6. 点击菜单栏箭头打开独立托盘。点击外部、切换窗口、再次点击箭头或按 `Esc` 可收起托盘。
7. 如果需要原始菜单栏图案，在“权限与设置 → 增强托盘图标外观”中申请屏幕录制权限；没有原图时仍可使用应用身份图标。

## 托盘交互

独立托盘是代理入口，不是第三方原生菜单的复制品：

- **左键**：对已确认的目标请求一次受支持的原生动作。对于受管理的隐藏项，Menu Tidy 可能先临时显示该项，确认目标界面出现后交还给用户使用，结束后恢复隐藏。
- **右键**：打开 Menu Tidy 自己的上下文菜单，可选择“打开菜单”或“常驻菜单栏”。它不转发第三方应用的原生右键事件。
- **快捷键**：`Control + Option + M` 切换独立托盘。
- **图像**：原始图像是最近一次成功采集的快照，可能落后于目标应用的实时状态；图像可用性与原生动作支持是两项独立能力。

## 权限与数据

| 权限 | 用途 | 是否必需 |
| --- | --- | --- |
| 辅助功能 | 读取菜单栏项目、确认身份和位置、调用目标支持的原生动作 | 必需 |
| 菜单栏显示设置文件 | macOS 27 的原生隐藏、临时显示和恢复 | 使用原生隐藏路径时必需 |
| 排序目录 | 旧位置恢复或兼容路径 | 仅在对应功能使用时需要 |
| 屏幕录制 | 采集已确认的小区域原始图像 | 可选 |

分类选择和更新偏好通常保存在 `~/Library/Preferences/dev.hdh.MenuTidy.plist`。后台事务与恢复日志位于 Application Support；原始图标快照只保存在内存中，退出应用后需要重新采集。详细位置见[用户数据与存储位置](docs/USER-DATA.md)。

## 已知限制

Menu Tidy 对系统和第三方实现保持保守判断，以下情况会显示为待确认、离线或失败：

- 目前扫描和图像采集主要针对主显示器；系统溢出区和原生菜单仍受 macOS 空间布局限制。
- 顶部浮层、展开的菜单、全屏窗口或其他菜单栏工具可能阻塞 AX 读取；刷新超时会保留已有列表和用户选择。
- macOS 27 使用缓存快照，隐藏期间不会实时同步图标动画、计数或网络状态；实际状态以原生菜单为准。
- 受保护的系统项目、身份不唯一的项目、缺少可验证位置的项目不会被猜测归类。
- 后台打开动作按应用分别验证；一个应用的成功不代表其他应用也支持。必要时可把项目改为常驻显示后从原生菜单栏使用。
- 保存的规则、AX 动作返回成功或截图缓存都不单独构成隐藏完成证明；真实状态未确认时会保留待处理提示。

### 刷新显示“菜单栏读取未及时完成”

先关闭正在展开的菜单、系统溢出区和其他菜单栏工具，再点击“刷新”。如果目标应用没有运行，只能在“离线与保留记录”中看到保存的选择。连续超时不会删除规则；它表示本轮 AX 扫描没有在时间预算内完成。仍然失败时，重启 Menu Tidy 或 MenuBarAgent 后再试，并在 [Issues](https://github.com/cyruss648/menu-tidy/issues) 附上 macOS 版本、应用版本和复现步骤。

### 托盘没有原始图像

屏幕录制权限只影响原始外观采集，不影响列表、应用身份图标或托盘入口。展开系统溢出区并保持片刻后刷新，应用会在身份和位置都确认后补采；无法确认时继续使用应用身份图标。

## 文档

- [文档索引](docs/README.md)：按使用、架构、验证和发布分类的入口。
- [独立托盘体验](docs/TRAY-EXPERIENCE.md)：托盘交互、图像回退、原生动作和恢复边界。
- [统一图标管理页](docs/UNIFIED-MANAGEMENT.md)：三态选择、批量应用、重试和离线记录。
- [原生隐藏研究](docs/NATIVE-VISIBILITY-RESEARCH.md)：macOS 版本差异、系统接口和证据边界。
- [应用内更新](docs/AUTO-UPDATE.md)：Sparkle 通道、签名 feed 和更新状态。
- [资源占用验证](docs/RESOURCE-USAGE.md)：缓存托盘、窗口释放和测量条件。
- [0.6.5 回归验证](docs/ACCEPTANCE-0.6.5.md)：当前版本的自动化检查和实机验证边界。
- [开发指南](docs/DEVELOPMENT.md)：本地工具链、调试、测试和签名。
- [发布指南](docs/RELEASING.md)：双架构打包、签名、feed 和发布流程。

## 开发

```sh
git clone https://github.com/cyruss648/menu-tidy.git
cd menu-tidy
./scripts/dev-setup.sh
./scripts/check.sh --full
./scripts/build.sh release
```

构建产物输出到 `dist/Menu Tidy.app`。`dev-setup.sh` 只检查依赖并安装仓库 Git hooks，不会自动安装软件或创建签名证书。开发时可以使用隔离的本地签名身份，详见[固定本地签名身份](docs/LOCAL-SIGNING.md)。

提交前建议运行：

```sh
./scripts/check.sh --full
```

自动化检查证明源码、脚本和隔离测试环境通过；它不替代真实第三方菜单栏、权限撤销、睡眠唤醒、多显示器和 Intel 桌面交互验收。每个版本的具体范围以对应 [Release](https://github.com/cyruss648/menu-tidy/releases) 和 `docs/` 验证记录为准。

## 参与贡献

请先阅读[开发指南](docs/DEVELOPMENT.md)，再提交 Issue 或 Pull Request。报告菜单栏问题时，提供以下信息会更容易复现：

- macOS 版本、芯片架构和 Menu Tidy 版本/构建号；
- 目标应用是否正在运行、是否使用其他菜单栏整理工具；
- 发生问题前的操作顺序，以及界面中的完整错误文本；
- 相关日志中的时间、阶段和 AX 返回码。不要提交账号、密钥、恢复文件原文或完整菜单栏内容。

## 版本与许可证

当前源码版本为 **0.6.6（构建 62）**。版本变更见 [CHANGELOG.md](CHANGELOG.md)，公开可安装版本以 [GitHub Releases](https://github.com/cyruss648/menu-tidy/releases) 为准。

本仓库当前未包含 `LICENSE` 文件。使用、再分发或将代码集成到其他项目之前，请先确认仓库维护者公布的许可条款。
