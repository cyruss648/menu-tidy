# Menu Tidy 0.3.1 发布与安装验收

记录日期：2026-09-23。发布版本 **0.3.1 / build 9**，源码提交 [`1a24ab4`](https://github.com/cyruss648/menu-tidy/commit/1a24ab4a6723181096ba7d7b3d13900bd4322ba1)。以下区分自动构建、发布产物及本机运行证据。

## GitHub 发布

公开仓库：[cyruss648/menu-tidy](https://github.com/cyruss648/menu-tidy)。正式附件位于 [v0.3.1 Release](https://github.com/cyruss648/menu-tidy/releases/tag/v0.3.1)，标记为 **Prerelease**，未标记为稳定版 Latest。

| 验证 | 结果与证据 |
| --- | --- |
| 普通提交构建 | [CI 35824027310](https://github.com/cyruss648/menu-tidy/actions/runs/35824027310) 成功，Apple Silicon 和 Intel 原生检查、测试及打包通过。 |
| 手动签名验证 | [CI 35824035903](https://github.com/cyruss648/menu-tidy/actions/runs/35824035903) 成功，两个架构均实际签名并打包；每个架构 35 项核心测试通过。该运行未创建 Release。 |
| 标签发布 | [CI 35824299031](https://github.com/cyruss648/menu-tidy/actions/runs/35824299031) 的两个构建任务与发布任务全部成功。 |
| 附件完整性 | 两个架构各包含 ZIP、`.sha256`、`.metadata.json`，共六个附件；工作流验证摘要、版本、源码提交、干净工作区及两架构签名一致后才公开草稿。 |
| 签名清理 | 两个 runner 的临时钥匙串清理步骤成功；不修改全局证书信任。 |

发布包使用项目专用自签名证书，**不是 Apple Developer ID，未经过 Apple 公证**。`codesign` 校验成功不等于 Gatekeeper 放行证明。

## 从 GitHub 下载并安装

在 Apple Silicon、macOS 27 上，从上述 Release 下载 `Menu-Tidy-0.3.1-macos-arm64.zip` 及其校验文件和元数据，随后解压安装。安装来源为 GitHub Release 附件。

- GitHub API 提供的三个已下载附件的 digest 与实际文件相符。
- ZIP 的 SHA-256 与 `.sha256`、元数据一致：`593f9f29a5b4fdf66f7958b9dad0759ee66ccf9b01e96bfc779192192c96e083`。
- 元数据源码提交与 `v0.3.1` 一致，`dirty=false`；版本为 0.3.1、build 9，Mach-O 架构为 arm64。
- 解压包通过严格签名验证及显式证书约束验证，证书 SHA-1：`67D4358A865A268F70CADF16091219C40937D11B`。
- 退出旧版 0.2.3 后，将其移至 `~/Library/Application Support/Menu Tidy/Backups/` 备份，再安装到 `/Applications/Menu Tidy.app`，保留用户偏好及分组规则。
- 安装后的可执行文件 SHA-256 与发布元数据完全相符：`39e64ef5edca196a6fdd6bc53dc25ebb462c2038934f940733926ca496bffbff`。
- 已从固定安装路径成功启动；系统中只有一个 MenuTidy 进程，路径为 `/Applications/Menu Tidy.app/Contents/MacOS/MenuTidy`。

## 界面与权限检查

发布包已成功打开管理界面，并显示保留的 AutoFocus 常驻规则。本次从本地开发签名切换到专用发布签名，首次启动显示等待授权；系统中的旧开关没有被当作当前签名已授权的证据。

用户在系统设置中移除旧条目并重新添加当前安装副本后，应用自动显示「辅助功能已开启」，没有依赖重启。随后点击「重新检测」，界面明确显示 macOS 已允许当前运行副本访问辅助功能。

主屏读取到 **24 个菜单栏项目**；刷新操作完成后列表仍可用，AutoFocus 常驻规则保留。界面按钮依次切换到「已收起」「已展开」，结束时恢复展开状态。该检查证明应用状态切换，不证明每个图标在系统溢出区外实际可见。

偏好保持自动收起关闭、快捷键开启、启动时收起开启、登录启动关闭。此次没有修改这些偏好，也没有重新执行快捷键或登录启动验收。

启动时检测到 Bartender 7 同时运行，界面显示整理器冲突提示。本轮未执行图标分类移动，未把界面启动成功计为三类图标功能通过。

## 失败记录与验证范围

首次普通 CI 暴露 Swift 6.2 的 AX 闭包捕获隔离诊断，已改为同一 actor 内顺序读取，并由后续双架构 CI 验证。`v0.3.0` 标签保留；其[签名发布任务](https://github.com/cyruss648/menu-tidy/actions/runs/35823608500)因临时钥匙串未注册到搜索列表而失败，没有生成 GitHub Release。修复增加搜索列表注册和实际签名预检后，使用新标签 `v0.3.1` 发布。

[0.2.3 实机报告](ACCEPTANCE-0.2.3.md)仍是图标移动与可见性行为的历史依据。当前 macOS 27 刘海屏容量限制仍然存在，普通展开可能需要系统 overflow。此次 CI 与安装验证不扩展到 Intel 桌面交互、macOS 13 实机、多显示器、全屏、睡眠恢复、登录启动或快捷键完整验收。
