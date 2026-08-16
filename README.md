# 🐋 Orca DSH Launcher

> 为 **DeepSeek Harness (DSH)** 打造的一站式助手：帮你检查更新、开关服务器、常驻托盘、图形化管理，还能在全新电脑上**一键装好 DSH**。

![版本](https://img.shields.io/badge/版本-v1.6.0-36D199) ![平台](https://img.shields.io/badge/平台-Windows-0078D6) ![许可证](https://img.shields.io/badge/许可证-MIT-green)

---

## 这是什么？

DeepSeek Harness（简称 DSH）是一个开源项目，但安装和使用对新手不太友好——要敲命令、查端口、看日志。

**Orca DSH Launcher** 就是来解决这个问题的。它把 DSH 常用操作做成了「点一下就行」：

| 能力 | 有什么用 |
|---|---|
| 🚀 一键安装 DSH | 全新电脑上双击一个程序，自动帮你下载安装最新版 DSH（自动检测网络、可自选安装位置） |
| 🔔 更新检查 | 每次启动 DSH 自动对比官方最新版本，有更新就提醒你（只提醒，绝不偷偷更新） |
| ▶️ 服务器开关 | 在聊天框里输入命令，就能启动/关闭 DSH、打开网页界面 |
| 🐳 系统托盘 | 右下角一只虎鲸，点一下开界面，右键菜单开关服务器、检查更新 |
| 🖥️ 图形控制台 | 一个独立的管理窗口，看状态、看日志、改设置，DSH 没开也能打开 |

> ⚠️ 一个原则：**只检查、只提醒，绝不自动更新你的 DSH**。要不要更新、什么时候更新，永远由你自己决定。

---

## 🚀 快速开始

### 方式一：一键安装（推荐，适合没装过 DSH 的电脑）

1. 去本项目的 **Releases** 页面下载 `orca-setup.exe`
2. 双击运行，按提示操作：
   - 程序会先检查你的电脑环境（需要 Node.js、Git 等，缺什么会告诉你去哪装）
   - 再检查网络能否访问 GitHub（网络不好的话会明确告诉你原因和解决办法）
   - 然后让你选择把 DSH 安装到哪个文件夹
   - 最后自动下载、安装、启动 DSH，并把本插件一起装好
3. 完成后浏览器会自动打开 DSH 界面

### 方式二：已经装好 DSH，只想装这个插件

1. 下载本仓库代码（点页面右上角绿色 **Code** 按钮 → Download ZIP），解压
2. 双击运行 `scripts\install.ps1`
3. 重启 DSH，完成

> 装好之后，桌面会出现一个「Orca DSH Launcher」图标，双击可以打开管理窗口。

---

## 🎮 使用方法

### 在 DSH 聊天框里输入命令

| 命令 | 作用 |
|---|---|
| `/orca 状态` | 查看服务器、端口、更新状态 |
| `/orca 检查` | 立即检查是否有新版本 |
| `/orca 启动` | 启动 DSH 服务器 |
| `/orca 关闭` | 关闭 DSH 服务器 |
| `/orca 重启` | 一键重启 DSH 服务器 |
| `/orca 打开` | 打开 DSH 网页界面（没启动会自动先启动） |
| `/orca 日志` | 查看最近运行日志 |
| `/orca 端口` | 查看端口占用情况 |
| `/orca 配置` | 查看当前配置 |
| `/orca 诊断` | 一键检查电脑环境是否健康 |
| `/orca 控制台` | 打开图形管理窗口 |
| `/orca 托盘` | 启动系统托盘 |
| `/orca 关闭托盘` | 关闭系统托盘 |
| `/orca 帮助` | 显示帮助 |

也可以输入英文：`/orca status`、`/orca start`、`/orca stop`……

### 系统托盘（右下角虎鲸图标）

- **左键**：打开 DSH 网页界面
- **右键菜单**：打开界面 / 打开控制台 / 检查更新 / 启动服务器 / 关闭服务器 / 退出

### 图形控制台（独立管理窗口）

- **概览**：一眼看到服务器、更新、托盘三个状态
- **服务器**：启动 / 关闭 / 重启，端口被占用了会明确告诉你是谁占的
- **日志**：实时查看 DSH 运行日志
- **设置**：端口、DSH 目录、开机自启、深色/浅色主题
- **关于**：版本和使用统计

---

## ⚙️ 配置文件

配置文件在 `C:\Users\你的用户名\.dsh\orca-dsh-launcher.json`，一般不需要手动改（控制台里可以改）：

```json
{
  "dshDir": "D:\\deepseek harness",
  "port": 3080,
  "repo": "deepseek-ai/deepseek-harness",
  "branch": "master",
  "checkTimeoutMs": 8000,
  "trayAutoStart": true,
  "theme": "dark"
}
```

| 字段 | 含义 | 默认值 |
|---|---|---|
| `dshDir` | DSH 安装在哪里 | `D:\deepseek harness` |
| `port` | DSH 网页界面端口 | `3080` |
| `repo` | 官方仓库 | `deepseek-ai/deepseek-harness` |
| `branch` | 检查的分支 | `master` |
| `checkTimeoutMs` | 网络查询超时（毫秒） | `8000` |
| `trayAutoStart` | 启动 DSH 时自动拉起托盘 | `true` |
| `theme` | 控制台主题（深色/浅色） | `dark` |

---

## 📦 项目结构

```
orca-dsh-launcher/
├── orca-setup.ps1      ← 一键安装引导器（全新电脑装 DSH 用）
├── plugin.js           ← 插件本体（更新检查 + 命令 + 拉起托盘/控制台）
├── package.json        ← 插件身份 + 版本号
├── orca/               ← 桌面端组件
│   ├── orca-common.ps1 ← 公共逻辑库（托盘和控制台共用）
│   ├── dsh-tray.ps1    ← 系统托盘
│   ├── dsh-console.ps1 ← 图形管理窗口
│   └── ...（启动器、图标等）
├── scripts/
│   ├── install.ps1     ← 一键安装插件到 DSH
│   ├── uninstall.ps1   ← 一键卸载
│   ├── test-all.ps1    ← 一键全量测试
│   └── build-exe.ps1   ← 把引导器打包成 EXE
└── test/               ← 测试脚本
```

---

## 🧑‍💻 开发者指南

### 两份代码，别搞混

- **项目版本**（本仓库）：你下载、修改、发布的代码
- **运行版本**：电脑上实际被 DSH 加载的代码，位置在 `C:\Users\你的用户名\.dsh\profiles\web\node_modules\orca-dsh-launcher\`

改完代码后，需要把改动同步到运行版本（运行 `scripts\install.ps1` 即可，它会自动备份并覆盖）。

### 改完代码必须做的事

1. 运行 `scripts\test-all.ps1` 全量测试（5 项检查全过才行）
2. 同步到运行版本
3. 更新 `CHANGELOG.md`

详细开发规范见 [CONTRIBUTING.md](CONTRIBUTING.md)。

---

## 📜 许可证

[MIT](LICENSE)

---

📝 完整更新记录见 [CHANGELOG.md](CHANGELOG.md)

---

## 🐳 关于虎鲸

虎鲸（Orca）是海洋里的顶级猎手，聪明、优雅、擅长团队协作——就像这个工具想成为的样子：安静地守护你的 DSH，需要的时候一叫就到。
