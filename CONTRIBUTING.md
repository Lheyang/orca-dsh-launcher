# 贡献指南（CONTRIBUTING）

本文件面向要改这个项目代码的人（包括 AI 助手）。用户文档见 [README.md](README.md)，
仓库规则浓缩版见 [AGENTS.md](AGENTS.md)，变更记录见 [CHANGELOG.md](CHANGELOG.md)。

## 1. 这个项目是什么

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（DSH）的 Windows
桌面伴侣 + Cordis 插件：更新检查、服务器启停、系统托盘、图形控制台、一键安装。

**v2.0.0 起底层是 C# / .NET 8**（WPF 窗口 + WinForms 托盘），编译成原生 exe；
v1.x 的 PowerShell / VBScript 实现保留在 `legacy/`，**只读参考，不再维护**。

唯一保留的 JavaScript 是 `plugin.js`（DSH 用 Node 在自己进程里加载插件，这是硬约束）
和 `lib/client.js`（跑在浏览器里的聊天界面客户端插件）。

## 2. 开发环境

| 用途 | 需要 |
|---|---|
| 编译 | [.NET 8 SDK](https://dotnet.microsoft.com/zh-cn/download/dotnet/8.0) |
| 运行（框架依赖版） | .NET 8 Desktop Runtime |
| 跑 plugin.js 测试 | Node.js |
| DSH 本体 | Node.js + git + pnpm |

`scripts\_find-dotnet.cmd` 会自动找 SDK：先看 PATH 上的 `dotnet`，再看
`%USERPROFILE%\.dotnet\dotnet.exe`（便携安装也能用）。

## 3. 常用命令

```bat
build.cmd        编译（Release）
test.cmd         全量测试（5 步，见下）
install.cmd      编译 + 组装 + 安装进 DSH（自动备份、自动重启托盘）
uninstall.cmd    卸载（自动备份）
publish.cmd      打分发包（dist\stage、payload.zip、orca-setup.exe）
```

`test.cmd` 的 5 步：

1. 编译整个解决方案；
2. `orca-cli selftest`（9 项：版本号 / 配置读写往返 / 端口探测 / 统计原子写 /
   图标资源 / 快捷方式创建删除 / `cordis.patch.yml` 登记反登记 / 日志 / 环境探测）；
3. `node` 加载 `plugin.js`，校验 `apply` 与 `inject: ['commands']`；
4. `orca-cli quick-check`（状态 JSON）；
5. `tests\real-cordis-test.mjs`：用 DSH 真实的 Cordis 运行时加载插件并真调一次
   `/orca 状态`（最接近 DSH 实际路径的验证）。

**提交前至少跑一遍 `test.cmd`。**

## 4. 代码结构与职责边界

```text
src/Orca.Core/    【核心】所有业务逻辑都写在这里（配置、端口、启停、构建检查、
                  更新检查、统计、快捷方式、登记文件、安装流程、主题、对话框）
src/Orca.App/     只做界面：托盘、控制台窗口、安装向导（一个 orca.exe 四种模式）
src/Orca.Cli/     只做参数解析与输出：/orca 子命令 + install/uninstall/quick-check/selftest
plugin.js         只做转发：注册 /orca -> 调 orca-cli.exe -> 返回 {kind,text}
```

**新增功能时先问自己：这段逻辑属于 Core 吗？** 界面里只允许写"取值、显示、
调用 Core、更新界面"这四类代码。绝不允许在 `plugin.js` 里重写桌面端逻辑。

## 5. 编码规范（踩过的坑，务必遵守）

### 5.1 文件编码

| 文件类型 | 编码 | 原因 |
|---|---|---|
| `.cs` / `.xaml` / `.md` / `.js` / `.json` | UTF-8（无 BOM） | Roslyn / XAML / Node 都按 UTF-8 解析 |
| `.cmd` | **GBK / ANSI** | cmd.exe 按系统 OEM 代码页读批处理；UTF-8 中文会被按 GBK 解码并吞掉后面的 ASCII 字符，直接语法错误 |
| DSH 配置（`cordis.patch.yml`、`orca-dsh-launcher.json`、`orca-stats.json`） | UTF-8 **无 BOM** | DSH / Node 侧按 UTF-8 读；一律走 `Utf8Files` 读写 |

`.cmd` 里**不要写 emoji**（GBK 无法表示），控制台标记统一 `[OK]` / `[失败]` / `[跳过]`。

### 5.2 XML 注释

`.csproj` / `.proj` 的 XML 注释里**不能出现连续两个减号**，否则 MSBuild 报 MSB4025。
写命令行参数示例时改成「加参数 console」这样的说法。

### 5.3 全局 using

`UseWindowsForms=true` 会引入 `System.Drawing` / `System.Windows.Forms` 全局 using，
与 `System.IO.Path`、`System.Windows.Media.Color`、`System.Windows.Point` 冲突。
各 csproj 已统一处理：

```xml
<ItemGroup>
  <Using Include="System.IO" />
  <Using Remove="System.Drawing" />
  <Using Remove="System.Windows.Forms" />
</ItemGroup>
```

需要 Drawing / Forms 类型的文件自己 `using` 或全限定（例如 `IconLoader.cs`）。

### 5.4 界面不许卡

所有可能耗时的操作（网络查询、启停服务器、构建、安装）在界面里一律
`await Task.Run(...)`；界面刷新用 `DispatcherTimer` + 防重入标志。

### 5.5 主题与配色

换色走 `ThemeApplier.SetBrush`（内部 Remove + Add，避免 DynamicResource 报
"invalid value"）；颜色定义只写在 `ThemePalette` / `AccentPresets` 两处。

### 5.6 中文注释

面向非程序员维护者，新代码写中文注释，说明"为什么"而不只是"做什么"。

## 6. 关键技术纪律（改这些地方要特别小心）

- **端口归属判断**：`GetExtendedTcpTable` 取监听 PID → 读目标进程 PEB 拿命令行 →
  正则 `pnpm|dsh|deepseek|harness|tsx`。命令行读不到时按"未知占用者"处理：
  **既不启动也不关闭**，绝不误杀其他 Node 进程。
- **`/orca 关闭`、`/orca 重启` 必须脱钩执行**：`orca-cli.exe` 是 DSH 服务器进程的
  子进程，直接 `taskkill /T` 会把自己一起杀掉、回复发不出去。所以走
  `DshServer.StopDetached` / `RestartDetached`（派一条后台命令串，本进程先退出）。
- **拉起常驻程序必须 `UseShellExecute = true`**：否则子进程会继承调用方的 stdout
  管道并一直占着，导致 `plugin.js` 的 `execFile` 永远等不到输出结束而挂住。
- **升级要先请旧程序退出**：`bin\*.dll` 会被运行中的托盘/控制台锁定。
  `InstallService.InstallPlugin` 会先发退出信号、等它们退出（兜底只杀插件目录里的
  `orca.exe`），复制带重试，装完再把托盘拉起来。
- **更新检查只查询**：对比本地 git 提交号与官方 `master`，**绝不自动更新**，
  绝不改动 DSH 源码。
- **单实例/联动信号名沿用 v1.x**（`Local\DSH-Tray-Single`、
  `Local\Orca-Console-Show/Close`、`Local\Orca-Tray-Close`），保证新旧版本混装
  时也不会开两个托盘、能互相优雅关闭。

## 7. 用户数据保护

`~/.dsh/` 下这些**任何时候不要删**：

- `orca-dsh-launcher.json`（配置，保存时保留用户手加的字段）
- `orca-stats.json`（使用统计，原子写入）
- `orca-dsh-server.log`（服务器日志，>2MB 自动轮转为 `.1`）
- `update-check-state.json`（更新检查结果）
- `orca-dsh-last-build.json`（构建缓存）
- `orca-backup/`（安装/卸载/升级前的自动备份）

测试只删自己生成的临时文件（`%TEMP%\orca-*`）。

## 8. 版本号

语义化版本 `主.次.补丁`，**`package.json` 是唯一来源**：

- `.cmd` 脚本读它并传给编译器（`-p:Version=`）；
- 程序运行时读它显示（`AppInfo.Version`，读不到时退回程序集版本）。

改版本只改三处：`package.json` + `CHANGELOG.md` + README 顶部 badge。

## 9. 提交规范

Conventional Commits：`type(scope): subject`

- type：`feat` / `fix` / `refine` / `docs` / `chore` / `style` / `test`
- scope：`core` / `console` / `tray` / `installer` / `cli` / `plugin` / `readme` / `ai` 等

例：

```text
feat(core): 端口归属判断改读进程 PEB
fix(cli): 关闭命令改脱钩执行，避免回复丢失
docs: 重写为 C# / .NET 8 架构
```

## 10. 发布流程

1. 改 `package.json` 版本号 + 写 `CHANGELOG.md` + 更新 README badge；
2. `test.cmd` 全绿；
3. `publish.cmd` 打包，得到 `dist\orca-setup.exe`（自包含单文件）；
4. 在干净环境（最好没装 .NET / DSH 的机器）双击 `orca-setup.exe` 走一遍向导；
5. 打 tag、上传 `dist\orca-setup.exe` 到 GitHub Releases。
