# Orca DSH Launcher — 仓库规则

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（DSH）的 Windows
桌面伴侣 + Cordis 插件：更新检查、服务器启停、系统托盘、WPF 图形控制台、一键安装
引导。插件经 `cordis.patch.yml` 挂载到 `dsh web`，**绝不修改 DSH 源码**。

**v2.0.0 起底层全部为 C# / .NET 8（WPF + WinForms）**，不再使用 PowerShell 与
VBScript。旧实现保留在 `legacy/` 仅供对照，**不要再改动它，也不要再新增 .ps1**。

维护者必读 [CONTRIBUTING.md](CONTRIBUTING.md)（本文件是其浓缩版）；用户文档见
[README.md](README.md)；变更记录见 [CHANGELOG.md](CHANGELOG.md)。

## 仓库布局

```text
plugin.js                DSH 插件入口（薄壳，唯一保留的 JS：Cordis 用 Node 进程内加载）
lib/client.js            DSH 聊天界面客户端插件（峰谷计费徽标，浏览器端运行）
package.json             插件身份 + 版本号（版本唯一来源）
cordis.patch.yml         bundle 配置层（dsh plugin add 用）
src/
  Orca.sln               解决方案
  Directory.Build.props  公共编译属性（目标框架 / 版本号 / 语言版本）
  Orca.Package.proj      打包脚本（MSBuild：组装插件包 / 打 payload / 打安装器）
  Orca.Core/             【核心】公共逻辑库，业务逻辑只写在这里
    OrcaPaths.cs           所有路径 + UTF-8 无 BOM 读写
    OrcaConfig.cs          共享配置读写（保留用户自定义字段）
    OrcaStats.cs           使用统计（原子写）+ 更新检查结果模型
    OrcaLog.cs             服务器日志轮转/读尾 + 安装日志
    NativeMethods.cs       Win32 P/Invoke + 读进程命令行（读 PEB，微秒级）
    PortInspector.cs       端口状态与归属判断（GetExtendedTcpTable）
    ProcessRunner.cs       隐藏窗口起进程 / 采集输出 / 杀进程树
    DshBuild.cs            构建检查（HEAD 变化或产物缺失才 build）
    DshServer.cs           启停 / 等待就绪 / 打开界面 / git pull 更新
    UpdateChecker.cs       更新检查 + GitHub API 取更新详情
    ShellShortcut.cs       .lnk 创建（IShellLink）+ 开机自启 / 桌面图标
    CordisPatch.cs         cordis.patch.yml 登记 / 反登记 / 旧插件迁移
    InstallService.cs      安装核心：环境+网络检测 / clone / install / build / npx / 装插件
    ThemePalette.cs        深浅主题色表 + 6 种强调色预设
    OrcaSignals.cs         单实例互斥 + 托盘/控制台进程间信号
    Ui/IconLoader.cs       多尺寸 ico 解码（WPF/托盘）
    Ui/ThemeApplier.cs     主题应用（写窗口资源字典）
    Ui/OrcaDialog.xaml     自定义对话框（替代系统 MessageBox）
  Orca.App/              桌面程序 orca.exe（一个 exe 四种模式）
    App.xaml.cs            模式分发：console / tray / setup / start-server
    TrayApp.cs             系统托盘（WinForms NotifyIcon）
    ConsoleWindow.xaml     图形控制台（6 页导航）
    SetupWindow.xaml       一键安装向导（6 步）
    Win32Helper.cs         任务栏图标 / AppUserModelID
    Assets/*.ico           虎鲸图标
  Orca.Cli/              命令行 orca-cli.exe（plugin.js 与 .cmd 脚本都调它）
legacy/                  v1.x 的 PowerShell / VBS 实现（只读参考，勿改）
build.cmd / test.cmd / install.cmd / uninstall.cmd / publish.cmd
scripts/_find-dotnet.cmd 找 SDK + 读版本号（被上面几个 .cmd 调用）
```

**职责边界**：业务逻辑一律放 `Orca.Core`；`Orca.App` 只做界面、`Orca.Cli` 只做
参数解析与输出；`plugin.js` 只负责在 DSH 内注册命令并转发给 `orca-cli.exe`，
**绝不在 JS 里重写桌面端逻辑**。

## 常用命令

```bat
build.cmd        编译（Release）
test.cmd         全量测试：编译 + orca-cli 自检 9 项 + plugin.js 加载 + quick-check
install.cmd      编译 + 组装插件包 + 安装进 DSH（自动备份 + 建快捷方式）
uninstall.cmd    卸载（自动备份）
publish.cmd      打分发包：dist\stage\ + payload.zip + dist\orca-setup.exe
```

诊断用：`orca.exe dialog-test`（参数前也可加两个减号）会连弹三个自定义对话框，
改过主题 / 强调色 / 对话框 XAML 后跑一下，确认渲染正常。

改动提交前至少跑一遍 `test.cmd`，改完 `install.cmd` 同步，再按改动重启 DSH
（`plugin.js`）/ 托盘或控制台（`src\`）。

## 环境要求

- **编译**：.NET 8 SDK（`scripts\_find-dotnet.cmd` 会自动找 PATH 上的 dotnet，
  或用户目录 `%USERPROFILE%\.dotnet\dotnet.exe`）。
- **运行**：.NET 8 Desktop Runtime（框架依赖版）。全新电脑用 `dist\orca-setup.exe`
  （自包含单文件，不需要预装 .NET）。
- **DSH 本体**：Node.js + git + pnpm。

## 编码约定（最容易踩的坑）

- **`.cs` / `.xaml` 用 UTF-8（无 BOM 即可）**，Roslyn 与 XAML 编译器都按 UTF-8 解析。
- **`.cmd` 必须 GBK/ANSI 编码**：cmd.exe 按系统 OEM 代码页读批处理，UTF-8 中文会
  被按 GBK 解码而吞掉后面的 ASCII 字符，直接导致语法错误。同理 `.cmd` 里**不要写
  emoji**（GBK 无法表示），控制台标记统一用 `[OK]` / `[失败]`。
- **XML 注释里不能出现连续两个减号**（`--`），`.csproj` / `.proj` 注释里写命令行
  参数时要绕开，否则 MSBuild 报 MSB4025。
- **DSH 配置文件（`cordis.patch.yml`、`orca-dsh-launcher.json`、`orca-stats.json`）
  是 UTF-8 无 BOM**：一律走 `Utf8Files`（`OrcaPaths.cs`）读写，别直接用
  `File.ReadAllText` 的默认编码。
- **全局 using 精简**：`UseWindowsForms` 会引入 `System.Drawing` / `System.Windows.Forms`
  的全局 using，和 `System.IO.Path`、`System.Windows.Media.Color` 等打架。各项目已在
  csproj 里 `<Using Remove=…>` 并补 `System.IO`，需要 Drawing/Forms 类型的文件自己
  显式 using 或全限定。
- **中文注释**：面向非程序员，新代码写中文注释。
- **WPF 资源字典赋值**：换主题色走 `ThemeApplier.SetBrush`（Remove + Add），
  别直接改索引器。
- **耗时操作不要放 UI 线程**：界面里一律 `await Task.Run(...)`（检查更新、启停
  服务器、安装步骤都已如此），否则窗口会假死。

## 关键技术纪律

- **端口归属判断**：`GetExtendedTcpTable` 拿 PID → 读目标进程 PEB 取命令行 →
  正则 `pnpm|dsh|deepseek|harness|tsx` 判断是否 DSH，**绝不误杀其他 Node 进程**；
  命令行读不到时按"未知占用者"处理（既不启动也不关闭）。
- **`/orca 关闭`/`重启` 用脱钩延迟执行**：`orca-cli.exe` 是 DSH 服务器进程的子进程，
  直接 `taskkill /T` 会把自己一起杀掉、命令回复发不出去。故 `DshServer.StopDetached`
  / `RestartDetached` 会派一条后台命令串（`timeout` → `taskkill` → 重新起服务器），
  本进程立刻退出后父子关系断开，不会被连带终止。
- **安装器负载**：`publish.cmd` 把 `dist\stage\` 压成 `orca-plugin-payload.zip`，
  再作为**嵌入资源**打进自包含单文件 `orca-setup.exe`；运行时
  `PluginPayload.Resolve()` 解压到临时目录（离线可装插件）。
- **进程管理**：安装/启动一律 `cmd /c … >> log 2>&1` 后台隐藏运行，界面用
  `DispatcherTimer`（800ms）轮询 `HasExited` + 日志尾部刷新。
- **更新检查只查询**：对比本地 git 提交号与官方 `master`，有更新记日志 + 通知，
  **绝不自动更新**，绝不改动 DSH 源码。
- **单实例与联动**：互斥体/事件名沿用 v1.x（`Local\DSH-Tray-Single`、
  `Local\Orca-Console-Show/Close`、`Local\Orca-Tray-Close`），因此新旧版本混装时
  也不会开出两个托盘，且能互相优雅关闭。

## 版本号规范

语义化版本 `主.次.补丁`，`package.json` 为唯一来源（`.cmd` 脚本读它传给 MSBuild，
程序运行时也读它显示）。改版本只需三处：`package.json` + `CHANGELOG.md` +
README 顶部 badge。

## 用户数据保护（重要）

`~/.dsh/` 下这些是**用户数据，任何时候不要删**：`orca-dsh-launcher.json`（配置）、
`orca-stats.json`（使用统计）、`orca-dsh-server.log`（服务器日志）、
`update-check-state.json`（更新检查结果）、`orca-dsh-last-build.json`（构建缓存）。
安装/卸载/升级前的自动备份统一放 `~/.dsh/orca-backup/`（**也不要删**）。
测试清理时只删自己生成的临时文件。

## 提交规范

Conventional Commits：`type(scope): subject`。type 用 `feat` / `fix` / `refine` /
`docs` / `chore` / `style` / `test`，scope 是主题（`core`、`console`、`tray`、
`installer`、`cli`、`readme`、`ai` 等）。例：`feat(core): 端口归属改读 PEB`、
`fix(cli): 关闭命令改脱钩执行`、`docs: 重写为 C# 架构`。

## 给 AI 代理的补充

- 本仓库另提供 [llms.txt](llms.txt)（概要）与 [llms-full.txt](llms-full.txt)
  （全文），供 LLM 爬虫/外部索引使用；本文件是仓库内开发的权威规则。
- 项目版本（本仓库）与运行版本
  （`~/.dsh/profiles/web/node_modules/orca-dsh-launcher/`）可能不同步，改完必须
  `install.cmd` 同步，**不要直接改运行版本**。
- `legacy/` 只是历史参照。需要了解某个行为的原始实现时可以读，但**不要修改、
  不要复活**其中任何脚本。
