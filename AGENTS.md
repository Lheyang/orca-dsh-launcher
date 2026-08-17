# Orca DSH Launcher — 仓库规则

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（DSH）的 Windows
桌面伴侣 + Cordis 插件：更新检查、服务器启停、系统托盘、WPF 图形控制台、一键安装
引导。插件经 `cordis.patch.yml` 挂载到 `dsh web`，**绝不修改 DSH 源码**。维护者
必读 [CONTRIBUTING.md](CONTRIBUTING.md)（本文件是其浓缩版）；用户文档见
[README.md](README.md)；变更记录见 [CHANGELOG.md](CHANGELOG.md)。

## 仓库布局

```text
plugin.js                Cordis 插件本体（node）：更新检查 / /orca 命令 / 拉起托盘与控制台
lib/client.js            DSH 聊天界面客户端插件（计费徽标等）
package.json             插件身份 + 版本号（版本唯一来源）
orca/
  orca-common.ps1         公共逻辑库【核心】配置 / 启停 / 端口检测 / 统计 / 更新检查（托盘+控制台共用）
  orca-install.ps1        安装核心逻辑库（一键安装完整版 / 官方 Web 版）
  dsh-tray.ps1            系统托盘（WinForms NotifyIcon）
  dsh-console.ps1         图形控制台（WPF 导航界面）
  start-*.vbs/ps1         隐藏窗口启动器 / 开机自启入口
orca-setup.ps1            独立安装向导（打包为 dist/orca-setup.exe 单文件分发）
scripts/
  install.ps1             安装插件到 DSH（复制 + cordis.patch.yml 登记 + 自启 + 桌面图标）
  uninstall.ps1           卸载（自动备份）
  test-all.ps1            一键全量测试（7 项）
  build-exe.ps1           打包 EXE（ps2exe + payload 注入）
test/                     冒烟 / inject / real-cordis / payload 链路测试
```

**职责边界**：业务逻辑（配置/服务器/更新/统计）一律放 `orca-common.ps1`，托盘/控制台
只做界面；`plugin.js` 只负责 DSH 内的事，不重复实现桌面端逻辑。

## 常用命令

```powershell
# 全量测试（7 项：语法 / 插件加载 / 控制台自检 / 托盘自检 / 真实 Cordis / 引导器自检 / payload 链路）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-all.ps1

# 同步到 DSH 运行环境（~/.dsh/profiles/web/node_modules/orca-dsh-launcher/，自动备份）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1

# 打包 EXE（产物 dist\orca-setup.exe，上传 GitHub Releases）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-exe.ps1
```

改动提交前至少跑一遍 `test-all.ps1`，改完 `install.ps1` 同步，再按改动重启 DSH
（`plugin.js`）/ 托盘或控制台（`orca\`）。

## 编码约定（最容易踩的坑）

- **`.ps1` 必须 UTF-8 带 BOM**：PowerShell 5.1 按 ANSI/GBK 解析无 BOM 脚本，中文会
  乱码甚至语法错误。补救：`[System.IO.File]::WriteAllText($f, $content, (New-Object System.Text.UTF8Encoding($true)))`。
- **DSH 配置文件（`cordis.patch.yml`、`orca-dsh-launcher.json`、`orca-stats.json`）
  是 UTF-8 无 BOM**：读写必须用 .NET 方法显式指定
  `System.Text.UTF8Encoding($false)`；禁止 `Get-Content`/`Set-Content`（PS5.1 默认
  GBK 读会乱码）。
- **中文注释**：面向非程序员，新代码写中文注释。
- **避开只读自动变量**：`$pid`、`$host` 等只读，局部变量用 `$procId` 之类。
- **WPF 资源字典赋值**：不能直接 `$Resources['key'] = brush`（会触发 "invalid
  value" 崩溃），必须 `Remove + Add`。

## 关键技术纪律

- **端口归属判断**：`Get-NetTCPConnection` / `netstat -ano` 取 PID →
  `Get-CimInstance Win32_Process` 取命令行，正则 `pnpm|dsh|deepseek|harness|tsx`
  判断是否 DSH，**绝不误杀其他 Node 进程**。
- **payload 注入**：`build-exe.ps1` 把插件文件 zip→Base64 替换
  `orca-install.ps1` 中 `__PLUGIN_PAYLOAD_B64__` 占位符，EXE 单文件离线可装。
- **进程管理**：安装/启动全部 `Start-Process cmd /c ... >> log 2>&1` 后台运行，
  UI 用 `DispatcherTimer`（800ms）轮询 `HasExited` + 日志尾部刷新，避免阻塞界面。
- **更新检查只查询**：对比本地 git 提交号与官方 `master`，有更新记日志 + 通知，
  **绝不自动更新**，绝不改动 DSH 源码。

## 版本号规范

语义化版本 `主.次.补丁`，`package.json` 为唯一来源（托盘/控制台动态读取）。
改版本只需三处：`package.json` + `CHANGELOG.md` + README 顶部 badge。

## 用户数据保护（重要）

`~/.dsh/` 下这些是**用户数据，任何时候不要删**：`orca-dsh-launcher.json`（配置）、
`orca-stats.json`（使用统计）、`orca-dsh-server.log`（服务器日志）、
`update-check-state.json`（更新检查结果）。测试清理时只删自己生成的临时文件。

## 提交规范

Conventional Commits：`type(scope): subject`。type 用 `feat` / `fix` / `refine` /
`docs` / `chore` / `style` / `test`，scope 是主题（`console`、`tray`、`installer`、
`readme`、`license`、`ai` 等）。例：`feat(console): 新增计费时段卡片`、
`fix: 退出面板改为内嵌`、`docs(ai): 新增 llms.txt 引导 AI 爬虫`。

## 给 AI 代理的补充

- 本仓库另提供 [llms.txt](llms.txt)（概要）与 [llms-full.txt](llms-full.txt)
  （全文），供 LLM 爬虫/外部索引使用；本文件是仓库内开发的权威规则。
- 项目版本（本仓库）与运行版本
  （`~/.dsh/profiles/web/node_modules/orca-dsh-launcher/`）可能不同步，改完必须
  `install.ps1` 同步，**不要直接改运行版本**。
