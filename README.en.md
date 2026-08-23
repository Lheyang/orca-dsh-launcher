# 🐋 Orca DSH Launcher

🌏 **English** | [中文](README.md)

![Version](https://img.shields.io/badge/version-v2.1.1-36D199) ![Platform](https://img.shields.io/badge/platform-Windows-0078D6) ![Stack](https://img.shields.io/badge/C%23-.NET%208%20WPF-512BD4) ![License](https://img.shields.io/badge/license-MIT-green)

A **Cordis plugin + native desktop app** for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (DSH) that provides update checking, server start/stop, a system tray icon, a graphical console, and one-click installation.

> **Implementation**: since v2.0.0 the desktop side is native executables built with **C# / .NET 8 (WPF + WinForms)**, instead of PowerShell / VBScript. Startup and status polling are faster, and it is no longer affected by PowerShell execution-policy or script-encoding (BOM/GBK) differences.

## Features

- **Update check**: on DSH startup, compares the local git commit against the official `master` branch; logs a message + notification when an update exists. **Query only — never auto-updates, never touches DSH source.**
- **`/orca` command set**: 15 subcommands covering status / start / stop / restart / open / logs / port / config / diagnostics / console / tray / setup.
- **System tray**: WinForms `NotifyIcon` — left-click opens the DSH UI; right-click menu starts/stops the server, opens the console, checks for updates.
- **Graphical console**: WPF window (Overview / Server / **Install** / Logs / Settings / About), dark & light themes plus 6 accent colors; opens even when DSH is not running.
- **One-click install**: the console "Install" page or the standalone wizard `orca-setup.exe` (self-contained single file) supports two paths —
  - Full version: `git clone` + `pnpm install` + `pnpm run build` + `pnpm dsh web`;
  - Official Web version: `npx @deepseek-ai/dsh web` (Node.js only).
- **Automatic rebuild guard**: DSH is a source checkout, so a `git pull` without a rebuild breaks startup. Both the "start" and "update" paths run a build check first (rebuild only when HEAD changed or one of 6 key artifacts is missing).
- **Port ownership detection**: only stops the process when it is really DSH — **never kills unrelated Node processes**.
- **Billing badge**: a peak/off-peak DeepSeek pricing chip in the DSH chat header (Beijing time; peak 09:00-12:00 and 14:00-18:00 costs about 2x off-peak).

## Installation

### Try DSH quickly (official Web version, no plugin needed)

```sh
npx @deepseek-ai/dsh web
```

### Fresh machine: install DSH + this plugin in one click

Download **`orca-setup.exe`** from GitHub Releases and double-click it. It is a self-contained single file with the plugin package embedded — **nothing needs to be pre-installed** (not even .NET).

### Existing DSH: install the plugin from source

```bat
:: In the repository root:
install.cmd
:: Then restart DSH
```

What it does: builds the C# solution → assembles the plugin package → copies it to `~/.dsh/profiles/web/node_modules/orca-dsh-launcher/` → registers it in `cordis.patch.yml` (UTF-8 without BOM) → backs up and removes v1.x PowerShell assets → creates the startup tray shortcut and the desktop icon (skip with `--skip-startup` / `--skip-desktop`).

Building requires the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0); day-to-day use only needs the **.NET 8 Desktop Runtime** (or just use the self-contained `orca-setup.exe`).

Uninstall: `uninstall.cmd` (automatic backup; `--kill-tray` also closes the tray, `--keep-shortcut` keeps shortcuts).

## Usage

### `/orca` commands

| Command | Description | Chinese alias |
|---|---|---|
| `/orca status` | Server / port / update / tray status | `状态` |
| `/orca check` | Check for updates now | `检查` |
| `/orca start` | Start the DSH server | `启动` |
| `/orca stop` | Stop the DSH server (never kills non-DSH processes) | `关闭` |
| `/orca restart` | Restart | `重启` |
| `/orca open` | Open the UI (starts the server first if needed) | `打开` |
| `/orca log` | Recent server log | `日志` |
| `/orca port` | Port ownership details | `端口` |
| `/orca config` | Effective configuration | `配置` |
| `/orca health` | Environment health check | `诊断` |
| `/orca console` | Open the graphical console | `控制台` |
| `/orca tray` / `tray-stop` | Start / stop the tray | `托盘` / `关闭托盘` |
| `/orca setup` | Open the installation wizard | `安装` |
| `/orca help` | Help | `帮助` |

`plugin.js` forwards the subcommand to `bin\orca-cli.exe`; the handler returns `{ kind: 'success' | 'error', text }`. Configuration is re-read on every call, so console changes take effect immediately.

### Command line (works without DSH)

```bat
bin\orca-cli.exe run status         :: any /orca subcommand
bin\orca-cli.exe quick-check        :: status as JSON (for scripts / monitoring)
bin\orca-cli.exe selftest           :: 9 built-in checks
bin\orca.exe --console              :: graphical console
bin\orca.exe --tray                 :: system tray
bin\orca.exe --setup                :: installation wizard
bin\orca.exe --start-server         :: start the DSH server silently (autostart entry)
```

## Configuration

`~/.dsh/orca-dsh-launcher.json` (UTF-8 without BOM, shared by the tray, console and plugin; created with defaults on first run):

| Field | Meaning | Default |
|---|---|---|
| `dshDir` | Local DSH source directory | `D:\deepseek harness` |
| `port` | Web UI port | `3080` |
| `repo` | Official repository | `deepseek-ai/deepseek-harness` |
| `branch` | Branch to check | `master` |
| `checkTimeoutMs` | Network query timeout | `8000` |
| `trayAutoStart` | Auto-start the tray when DSH starts | `true` |
| `theme` | Console theme (`dark` / `light`) | `dark` |
| `accent` | Accent color (`green`/`blue`/`purple`/`amber`/`rose`/`slate`) | `blue` |

> Extra fields you add by hand are **preserved** when settings are saved.

User data (**do not delete**): `orca-dsh-launcher.json`, `orca-stats.json` (usage stats, atomic writes), `orca-dsh-server.log` (rotated above 2 MB), `update-check-state.json`, `orca-dsh-last-build.json`, `orca-backup/` (automatic install/uninstall backups).

## Architecture

```
plugin.js                DSH plugin entry (thin shell: registers /orca, forwards to orca-cli.exe)
lib/client.js            DSH chat client plugin (peak/off-peak billing chip)
src/
├── Orca.Core/           Shared logic: config / server control / port ownership / build check /
│                        update check / stats / shortcuts / installer / theming / custom dialog
├── Orca.App/            orca.exe — one program, four modes:
│                        --console (WPF console, 6 pages)
│                        --tray    (WinForms NotifyIcon)
│                        --setup   (WPF wizard, 6 steps)
│                        --start-server (silent server start)
├── Orca.Cli/            orca-cli.exe — all /orca subcommands + install/uninstall/selftest
└── Orca.Package.proj    packaging: plugin package → payload.zip → single-file orca-setup.exe
build.cmd test.cmd install.cmd uninstall.cmd publish.cmd
```

### Technical highlights

- **One exe, several modes**: `orca.exe` is a `WinExe`, so there is no console window and no need for `wscript` + `.vbs` wrappers — shortcuts simply pass an argument.
- **Port ownership**: `GetExtendedTcpTable` for the listening PID, then the target process PEB for its command line (microseconds, no WMI), matched against `pnpm|dsh|deepseek|harness|tsx`.
- **Detached stop/restart**: `orca-cli.exe` is a child of the DSH server process, so killing the process tree directly would kill itself; instead it schedules a background command chain (wait → taskkill → start) and exits first.
- **Installer payload**: the plugin package is zipped and embedded as a resource inside the self-contained `orca-setup.exe`, extracted to a temp folder at runtime (offline install works).
- **Responsive UI**: every long-running operation runs on a background thread; the UI refreshes through a `DispatcherTimer`.
- **v1.x compatible**: mutex and signal names are unchanged, so old and new versions never produce two trays and can close each other gracefully.

## Development

Requirements: Windows 10/11, [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0), Node.js (for the plugin load test).

```bat
build.cmd      :: build
test.cmd       :: full test suite (build + 9 selftests + plugin.js load + quick-check + real Cordis load)
install.cmd    :: sync into the DSH runtime (with backup)
publish.cmd    :: build the distributable (dist\orca-setup.exe)
```

Project version vs runtime version: the repository is the source of truth; `~/.dsh/profiles/web/node_modules/orca-dsh-launcher/` is what DSH actually loads. Always run `install.cmd` after changes — never edit the installed copy directly. See [CONTRIBUTING.md](CONTRIBUTING.md).

## FAQ

**What is Orca DSH Launcher?**
A Windows desktop companion and Cordis plugin for DeepSeek Harness (DSH, DeepSeek's open-source AI agent harness): update checks, server control, system tray, graphical console, one-click installation.

**Why was it rewritten in C# for v2.0.0?**
The desktop side used to be PowerShell scripts: restricted by execution policy, sensitive to script encoding (BOM/GBK), prone to UI stalls while querying status, and awkward to ship as a real executable. C# / .NET 8 gives compiled native programs — fast startup, smooth UI, simple distribution — with feature parity.

**Does it auto-update DSH?**
No. It only checks and notifies. It never auto-updates and never modifies DSH source files.

**Which platforms are supported?**
Windows 10 / 11. Regular use needs the .NET 8 Desktop Runtime (bundled inside `orca-setup.exe`); DSH itself needs Node.js and git.

**Do I need DSH installed first?**
For the plugin, yes. On a brand-new machine, `orca-setup.exe` installs DSH and the plugin for you.

**What about port conflicts?**
Port usage is checked before starting; non-DSH processes are **never killed**, and the owner is reported explicitly.

**Will upgrading to v2.0.0 lose my settings?**
No. Config, stats, logs and update state keep the same file names under `~/.dsh/`; old PowerShell assets are backed up to `~/.dsh/orca-backup/` before removal.

## Changelog

[CHANGELOG.md](CHANGELOG.md)

## For LLMs / crawlers

Machine-readable project descriptions: [llms.txt](llms.txt) (summary) and [llms-full.txt](llms-full.txt) (full text), kept in sync with this README.

## License

[MIT](LICENSE)

---

**About the orca**: orcas are smart, elegant and great team players — this tool aims to guard your DSH quietly and answer the moment you call.
