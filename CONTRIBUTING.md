# 项目规范（CONTRIBUTING）

> 本文件是 Orca DSH Launcher 的开发/维护规范，**维护者必读**。
> 违反规范不会报错，但会导致难以维护的隐患（乱码、同步丢失、统计误删等）。

---

## 一、文件结构与职责

```
orca-dsh-launcher\
├── orca-setup.ps1         ← 一键安装引导器（全新电脑装 DSH 用，可打包成 EXE）
├── plugin.js              ← 插件本体（node，DSH 加载；更新检查 + 命令 + 拉起桌面端）
├── package.json           ← 插件身份 + 版本号（版本唯一来源）
├── README.md              ← 用户文档
├── CHANGELOG.md           ← 更新日志（每版必更新）
├── CONTRIBUTING.md        ← 本规范
│
├── orca\                  ← 桌面端（PowerShell，随插件打包）
│   ├── orca-common.ps1    ← 公共逻辑库【核心】托盘+控制台共用
│   ├── dsh-tray.ps1       ← 托盘
│   ├── dsh-console.ps1    ← 控制台窗口（WPF）
│   ├── start-dsh-server.ps1/vbs ← 开机自启 DSH
│   ├── start-tray.vbs / start-console.vbs ← 隐藏窗口启动器
│   ├── dsh-tray.ico       ← 图标（托盘/窗口）
│   └── orca-icon.ico      ← 图标（桌面专用副本）
│
├── scripts\
│   ├── install.ps1        ← 一键安装
│   ├── uninstall.ps1      ← 一键卸载
│   ├── test-all.ps1       ← 一键全量测试
│   └── build-exe.ps1      ← 把引导器打包成单文件 EXE
│
└── test\                  ← 正式测试脚本（smoke / inject / real-cordis）
```

**职责边界**：
- 业务逻辑（配置/服务器/更新/统计）一律放 `orca-common.ps1`，托盘/控制台只做界面。
- 插件 `plugin.js` 只负责 DSH 内的事（更新检查、命令、拉起桌面端），不重复实现桌面端逻辑。

---

## 二、编码规范（最容易踩的坑）

1. **`.ps1` 文件必须保存为 UTF-8 带 BOM**
   - PowerShell 5.1 按 ANSI/GBK 解析无 BOM 的脚本，中文会乱码甚至语法错误。
   - 用文本编辑器/工具改完后检查：文件开头三个字节应为 `EF BB BF`。
   - 补救命令：`[System.IO.File]::WriteAllText($f, $content, (New-Object System.Text.UTF8Encoding($true)))`
2. **DSH 配置文件（`cordis.patch.yml`、`orca-dsh-launcher.json`、`orca-stats.json`）是 UTF-8 无 BOM**
   - 读写必须用 .NET 方法显式指定编码：`System.Text.UTF8Encoding($false)`。
   - 禁止用 `Get-Content`/`Set-Content`（PS5.1 默认 GBK 读会乱码）。
3. **DSH 命令名规范**：小写英文（`/orca`），handler 返回 `{kind:'success'|'error', text}`。
4. **WPF 资源字典赋值**：不能直接 `$Resources['key'] = brush`（PowerShell 索引器会触发 "invalid value" 崩溃），必须 `Remove + Add`（见 `Apply-Theme`）。
5. **避开只读自动变量**：`$pid`、`$host` 等是只读的，局部变量用 `$procId` 之类。
6. **中文注释**：面向非程序员，新代码写中文注释。

---

## 三、版本号规范

语义化版本 `主.次.补丁`：

| 变化 | 版本号 |
|---|---|
| 修 bug / 小调整 | 补丁 +1（v1.4.0 → v1.4.1） |
| 加新功能 | 次版本 +1（v1.4.0 → v1.5.0） |
| 重大重构 / 不兼容 | 主版本 +1（v1.x → v2.0.0） |

**改版本号只需两处**（v1.4.0 起版本单一来源）：
1. `package.json` → `version`（控制台/托盘自动读取，无需改代码）
2. 本 README 版本历史 + `CHANGELOG.md` 各追加一条

---

## 四、文件同步规范（项目版本 ↔ 运行版本）

- **项目版本**：本仓库代码（开发修改的地方）
- **运行版本**：`C:\Users\<用户>\.dsh\profiles\web\node_modules\orca-dsh-launcher\`（DSH 实际加载的地方）

改完代码必须同步，二选一：
1. 重跑 `scripts\install.ps1`（自动备份+覆盖+防重复，推荐）
2. 手动 `Copy-Item`（只同步改动的文件）

同步后按改动内容生效：
- 改了 `plugin.js` → 重启 DSH
- 改了 `orca\`（托盘/控制台/公共库）→ 重启托盘 / 重开控制台
- 改了图标 → 可能要清 Windows 图标缓存（换新文件名最省事）

---

## 五、测试规范

**改完代码必须跑 `scripts\test-all.ps1`**（5 项全查）：
1. PowerShell 语法检查（所有 .ps1）
2. 插件模块加载（node import）
3. 控制台状态自检（QuickCheck）
4. 托盘自检（-Test，5 秒自动退出）
5. 真实 Cordis 运行时加载（最接近 DSH 实际加载路径）

全部 ✅ 才能交付。

---

## 六、用户数据保护（重要）

`~/.dsh/` 下这些是**用户数据，任何时候不要删**：

| 文件 | 内容 |
|---|---|
| `orca-dsh-launcher.json` | 用户配置（端口/目录/主题/自启） |
| `orca-stats.json` | 使用统计（累计数据，删了就从 0 开始） |
| `orca-dsh-server.log` | 服务器日志（可轮转，但别主动删） |
| `update-check-state.json` | 更新检查结果 |

测试清理时只删自己生成的临时文件，**禁止删上述用户数据**。

---

## 七、命名规范

| 场景 | 规范 |
|---|---|
| PowerShell 函数 | 动词-名词（`Get-PortStatus`、`Start-DshServer`） |
| 文件 | 小写下划线（`orca-common.ps1`） |
| 快捷方式/菜单 | 中文（面向非程序员用户） |
| 配置字段 | 小驼峰（`trayAutoStart`、`checkTimeoutMs`） |
