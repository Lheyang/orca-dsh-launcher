# 🐋 Orca DSH Launcher

🌏 **中文** | [English](README.en.md)

![版本](https://img.shields.io/badge/版本-v1.6.0-36D199) ![平台](https://img.shields.io/badge/平台-Windows-0078D6) ![许可证](https://img.shields.io/badge/许可证-MIT-green)

为 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH) 提供更新检查、服务器启停、系统托盘、图形控制台与一键安装引导的 **Cordis 插件 + 桌面端组件**。

## 特性

- **更新检查**：DSH 启动时对比本地 git 提交号与官方 `master` 分支，有更新记日志 + 通知。**只查询，绝不自动更新。**
- **`/orca` 命令集**：14 个子命令，覆盖状态 / 启停 / 重启 / 日志 / 端口 / 配置 / 诊断 / 托盘 / 控制台。
- **系统托盘**：WinForms `NotifyIcon`，左键打开界面，右键菜单启停服务器、检查更新。
- **图形控制台**：WPF 管理窗口（概览 / 服务器 / **安装** / 日志 / 设置 / 关于），深/浅主题，DSH 未启动也能打开。
- **一键安装**：控制台「安装」页或独立向导 `orca-setup`（EXE 单文件分发），支持两条路径——
  - 完整版：`git clone` + `pnpm install` + `pnpm run build` + `pnpm dsh web`；
  - 官方 Web 版：`npx @deepseek-ai/dsh web`（只需 Node.js）。
- **未安装引导**：未安装 DSH 时，状态卡片与启动/打开按钮明确提示，并引导至安装页，不再静默失败。
- **计费时段卡片**：控制台概览页实时提示 DeepSeek 峰谷计费状态（北京时间高峰 09:00-12:00、14:00-18:00，高峰价约为空闲时段的 2 倍），帮您错峰省钱；卡片可收纳成**可拖动的小图标**，并支持「高峰开始前提醒」。

## 安装

### 快速体验 DSH（官方 Web 版，无需本插件）

```sh
npx @deepseek-ai/dsh web
```

### 安装本插件（已有 DSH）

```powershell
# 克隆仓库后执行
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1
# 重启 DSH 生效
```

脚本行为：复制运行文件至 `~/.dsh/profiles/web/node_modules/orca-dsh-launcher/` → 在 `cordis.patch.yml` 末尾追加 insert 登记（UTF-8 无 BOM）→ 自动迁移旧版 `dsh-update-checker` → 创建开机自启托盘快捷方式与桌面图标（可用 `-SkipStartupShortcut` / `-SkipDesktopShortcut` 跳过）。

卸载：`scripts\uninstall.ps1`（自动备份，`-KillTray` 顺带关托盘，`-KeepShortcut` 保留自启）。

### 一键安装 DSH（全新电脑）

- **方式一**：GitHub Releases 下载 `orca-setup.exe` 双击运行（内嵌插件包，单文件分发）。
- **方式二**：安装本插件后，打开控制台 →「安装」页，选择「一键安装完整版」或「启动官方 Web 版」。

## 用法

### `/orca` 命令

| 命令 | 说明 | 英文别名 |
|---|---|---|
| `/orca 状态` | 服务器 / 端口 / 更新状态 | `status` |
| `/orca 检查` | 立即检查更新 | `check` |
| `/orca 启动` | 启动 DSH 服务器 | `start` |
| `/orca 关闭` | 关闭 DSH 服务器（非 DSH 进程不误杀） | `stop` |
| `/orca 重启` | 一键重启 | `restart` |
| `/orca 打开` | 打开界面（未启动自动先启动） | `open` |
| `/orca 日志` | 最近运行日志 | `log` |
| `/orca 端口` | 端口占用详情 | `port` |
| `/orca 配置` | 当前生效配置 | `config` |
| `/orca 诊断` | 环境健康检查 | `health` / `diagnose` |
| `/orca 控制台` | 打开图形控制台 | `console` |
| `/orca 托盘` / `/orca 关闭托盘` | 启动 / 关闭托盘 | `tray` / `tray-stop` |
| `/orca 帮助` | 帮助 | `help` |

handler 返回 `{ kind: 'success' | 'error', text }`，每次执行重新读取配置（控制台改设置即时生效）。

### 托盘 / 控制台

- 托盘：左键打开界面；右键菜单含「打开控制台…」「检查更新」「启动/关闭服务器」「日志位置…」。
- 控制台「安装」页：DSH 完整版安装状态卡 +「一键安装完整版」「启动官方 Web 版」「打开 DSH 官网」三个入口，安装过程实时日志。

## 配置

`~/.dsh/orca-dsh-launcher.json`（纯 ASCII JSON，托盘/控制台/插件共用；首次运行自动生成默认值）：

| 字段 | 含义 | 默认 |
|---|---|---|
| `dshDir` | 本地 DSH 源码目录 | `D:\deepseek harness` |
| `port` | Web 界面端口 | `3080` |
| `repo` | 官方仓库 | `deepseek-ai/deepseek-harness` |
| `branch` | 检查分支 | `master` |
| `checkTimeoutMs` | 网络查询超时 | `8000` |
| `trayAutoStart` | DSH 启动时自动拉起托盘 | `true` |
| `theme` | 控制台主题 | `dark` |
| `peakReminder` | 高峰开始前提醒开关 | `false` |
| `peakReminderMin` | 提前提醒分钟数 | `15` |

> 高峰时段可自定义：配置里加 `peakWindows`（如 `"09:00-12:00,14:00-18:00"`，北京时间），即可覆盖官方默认时段。

用户数据（**勿删**）：`orca-dsh-launcher.json`（配置）、`orca-stats.json`（使用统计，原子写入）、`orca-dsh-server.log`（服务器日志，>2MB 自动轮转）、`update-check-state.json`（更新检查结果）。

## 架构

```
plugin.js                Cordis 插件：更新检查 / /orca 命令 / 拉起托盘与控制台
├── orca\
│   ├── orca-common.ps1   公共逻辑库：配置 / 启停 / 端口检测 / 统计 / 更新检查（托盘+控制台共用）
│   ├── orca-install.ps1  安装核心逻辑库：环境与网络检测 / git clone / pnpm install+build /
│   │                     npx web 启动 / 插件安装（向导+控制台共用）
│   ├── dsh-tray.ps1      系统托盘（WinForms NotifyIcon）
│   ├── dsh-console.ps1   图形控制台（WPF 导航界面）
│   └── start-*.vbs/ps1   隐藏窗口启动器 / 开机自启入口
├── orca-setup.ps1        独立安装向导（打包为 orca-setup.exe）
├── scripts\
│   ├── install.ps1       安装插件到 DSH（复制+登记+自启+桌面图标）
│   ├── uninstall.ps1     卸载
│   ├── test-all.ps1      全量测试（7 项）
│   └── build-exe.ps1     打包引导器 EXE（ps2exe + payload 注入）
└── test\                 冒烟 / inject / real-cordis / payload 链路测试
```

### 关键技术点

- **Cordis 插件形式**：对象插件 `{ name, inject: ['commands'], apply }`——必须显式声明 inject，否则 `cannot get property "commands" without inject`。
- **编码约定**：`.ps1` 必须 UTF-8 带 BOM（PowerShell 5.1 按 GBK 解析无 BOM 文件会乱码）；`cordis.patch.yml` 等 JSON/YAML 配置必须用 .NET 方法显式 UTF-8 无 BOM 读写（`Get-Content` 在 PS 5.1 按 GBK 读会乱）。
- **端口归属判断**：`Get-NetTCPConnection` / `netstat -ano` 取 PID → `Get-CimInstance Win32_Process` 取命令行，正则 `pnpm|dsh|deepseek|harness|tsx` 判断是否 DSH，避免误杀其他 Node 进程。
- **payload 注入**：`build-exe.ps1` 把插件文件打包成 zip→Base64，替换 `orca-install.ps1` 中 `__PLUGIN_PAYLOAD_B64__` 占位符；运行时解压到临时目录（EXE 单文件分发，离线可装插件）。
- **进程管理**：安装/启动全部 `Start-Process cmd /c ... >> log 2>&1` 后台运行，UI 用 `DispatcherTimer`（800ms）轮询 `HasExited` + 日志尾部刷新，避免阻塞界面。

## 开发

环境：Windows、PowerShell 5.1、Node.js（测试脚本用 node 加载插件）。

```powershell
# 全量测试（7 项：语法 / 插件加载 / 控制台自检 / 托盘自检 / 真实 Cordis 加载 / 引导器自检 / payload 链路）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-all.ps1

# 打包 EXE（产物 dist\orca-setup.exe，上传 GitHub Releases）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-exe.ps1
```

### 项目版本 vs 运行版本

- **项目版本**：本仓库代码（修改的地方）。
- **运行版本**：`~/.dsh/profiles/web/node_modules/orca-dsh-launcher/`（DSH 实际加载；`install.ps1` 自动同步并备份）。

改代码后：跑 `test-all.ps1` → 跑 `install.ps1` 同步 → 按改动重启 DSH（plugin.js）/ 托盘或控制台（orca\）。详细规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。

### 版本号

语义化版本，`package.json` 为唯一来源（托盘/控制台动态读取）。改版本只需：`package.json` + `CHANGELOG.md` + 本 README 顶部 badge。

## 常见问题（FAQ）

**Orca DSH Launcher 是什么？**
为 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（DSH，DeepSeek 开源 AI 智能体框架）打造的 Windows 桌面伴侣与 Cordis 插件：更新检查、服务器启停、系统托盘、图形控制台、一键安装。

**它会自动更新 DSH 吗？**
不会。它只检查并提醒，**绝不自动更新**，也绝不改动 DSH 的任何源码文件。

**支持哪些平台？**
Windows（PowerShell 5.1 / .NET Framework）。DSH 本体需要 Node.js 与 git。

**需要先装好 DSH 才能用吗？**
插件模式需要先有 DSH；全新电脑可直接用 `orca-setup.exe` 一键安装 DSH + 本插件。

**端口冲突怎么办？**
启动前自动检测端口占用；非 DSH 进程**不会误杀**，并明确提示占用者。

**和官方 Web 版（`npx @deepseek-ai/dsh web`）什么关系？**
那是 DSH 官方的最简启动方式（只需 Node.js）；本插件是在此基础上提供更新提醒、托盘、图形控制台和一键安装的增强工具。

## 变更记录

[CHANGELOG.md](CHANGELOG.md)

## 许可证

[MIT](LICENSE)

---

**关于虎鲸**：虎鲸（Orca）聪明、优雅、擅长团队协作——这个工具的目标是安静守护你的 DSH，需要时一叫就到。
