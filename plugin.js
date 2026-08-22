/**
 * ============================================================
 *  Orca DSH Launcher —— DSH 插件（薄壳）
 * ============================================================
 *
 * 【这个文件是干什么的】
 *   DSH（Cordis）用 Node 在自己进程内加载插件，所以插件入口必须是
 *   JavaScript —— 这是唯一保留 JS 的地方。
 *   从 v2.0.0 起，所有真正的逻辑都搬到了 C# 程序里：
 *
 *     bin/orca-cli.exe   命令行工具：/orca 的全部子命令、更新检查
 *     bin/orca.exe       桌面程序：系统托盘、图形控制台、安装向导
 *
 *   本文件只做三件事：
 *     1. DSH 启动时让 orca-cli.exe 后台跑一次更新检查（只查询，绝不自动更新）
 *     2. 按配置拉起 Orca 托盘（bin/orca.exe 加 tray 参数）
 *     3. 注册 /orca 斜杠命令，把子命令原样转发给 orca-cli.exe
 *
 * 【为什么这样拆】
 *   托盘 / 控制台 / 聊天命令共用同一套 C# 逻辑，行为绝对一致；
 *   插件侧不再调用 powershell.exe / netstat / taskkill，也没有第二套实现。
 *
 * 【它绝不做什么】
 *   - 绝不自动更新 DSH
 *   - 绝不改动 DSH 的任何源码文件
 *   - 所有失败都静默跳过，绝不影响 DSH 正常使用
 * ============================================================
 */

import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import { fileURLToPath } from 'node:url'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { homedir } from 'node:os'

const execFileAsync = promisify(execFile)

/* ------------------------------------------------------------
 * 路径：C# 可执行文件都在插件目录的 bin\ 下
 *   已安装环境：<插件目录>\bin\orca-cli.exe
 *   开发环境（直接在仓库里跑 DSH）：依次找 dist\stage\bin 与 src 编译输出，
 *   最后退回已安装位置，保证开发时 /orca 也能用。
 * ---------------------------------------------------------- */
const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url))
const INSTALLED_BIN = join(homedir(), '.dsh', 'profiles', 'web', 'node_modules', 'orca-dsh-launcher', 'bin')
const CONFIG_FILE = join(homedir(), '.dsh', 'orca-dsh-launcher.json')

/** 按优先级找一个存在的可执行文件 */
function resolveExe(name) {
  const candidates = [
    join(PLUGIN_DIR, 'bin', name),
    join(PLUGIN_DIR, 'dist', 'stage', 'bin', name),
    join(PLUGIN_DIR, 'src', name === 'orca.exe' ? 'Orca.App' : 'Orca.Cli', 'bin', 'Release', 'net8.0-windows', name),
    join(INSTALLED_BIN, name),
  ]
  for (const p of candidates) {
    if (existsSync(p)) return p
  }
  return candidates[0]
}

const CLI_EXE = resolveExe('orca-cli.exe')
const APP_EXE = resolveExe('orca.exe')

/** 读配置（只为了知道要不要自动拉起托盘；读不到就用默认值） */
function loadConfig() {
  try {
    return JSON.parse(readFileSync(CONFIG_FILE, 'utf8'))
  } catch {
    return { trayAutoStart: true }
  }
}

/** 桌面端程序是否就位 */
function cliReady() {
  return existsSync(CLI_EXE)
}

/** 缺文件时给用户的提示（比静默失败友好） */
function missingBinaryText() {
  return [
    '❌ 找不到 Orca 桌面端程序：',
    '   ' + CLI_EXE,
    '',
    '请重新安装本插件（在仓库目录双击 install.cmd，或运行 build.cmd 先编译）。',
  ].join('\n')
}

/**
 * 调用 orca-cli.exe 执行一个子命令，拿回 { kind, text }。
 * C# 端始终以退出码 0 返回，失败信息放在 kind=error 里，所以这里几乎不会抛。
 */
async function callCli(subcommand, timeoutMs = 300000) {
  if (!cliReady()) {
    return { kind: 'error', text: missingBinaryText() }
  }
  try {
    const { stdout } = await execFileAsync(CLI_EXE, ['run', subcommand, '--json'], {
      timeout: timeoutMs,
      windowsHide: true,
      maxBuffer: 8 * 1024 * 1024,
      encoding: 'utf8',
    })
    const line = String(stdout || '').trim().split(/\r?\n/).filter(Boolean).pop()
    const parsed = JSON.parse(line)
    if (parsed && typeof parsed.text === 'string') {
      return { kind: parsed.kind === 'error' ? 'error' : 'success', text: parsed.text }
    }
    return { kind: 'error', text: '命令返回了无法解析的结果。' }
  } catch (e) {
    // 超时或进程异常：把原始输出尽量带出来，方便排查
    const raw = String((e && (e.stdout || e.message)) || '').trim()
    return { kind: 'error', text: '执行 Orca 命令失败：' + (raw || '未知错误') }
  }
}

/** 后台跑一次更新检查（只写状态文件 + 记日志，不打扰用户） */
async function backgroundUpdateCheck(ctx) {
  if (!cliReady()) {
    ctx.logger?.warn('[orca-dsh-launcher] 桌面端程序缺失，已跳过更新检查（请重装插件）')
    return null
  }
  try {
    const { stdout } = await execFileAsync(CLI_EXE, ['update-check'], {
      timeout: 60000,
      windowsHide: true,
      encoding: 'utf8',
    })
    const state = JSON.parse(String(stdout || '{}').trim().split(/\r?\n/).pop())
    if (!state || !state.ok) {
      ctx.logger?.warn('[orca-dsh-launcher] 检查更新失败（本地或网络不可用），已安静跳过')
      return null
    }
    if (state.hasUpdate) {
      ctx.logger?.info('[orca-dsh-launcher] 🎉 发现 DSH 新版本！官方已更新到 ' + state.remoteShort + '，本地是 ' + state.localShort)
    } else {
      ctx.logger?.info('[orca-dsh-launcher] 当前已是最新版本 (' + state.localShort + ')')
    }
    return state
  } catch {
    ctx.logger?.warn('[orca-dsh-launcher] 检查更新失败（进程调用异常），已安静跳过')
    return null
  }
}

/** 拉起 Orca 托盘（桌面程序自带防重复，重复调用无副作用）
 *
 *  这里特意经 `cmd /c start /b` 中转一层：cmd 起完就退出，托盘的父进程随即消失，
 *  于是托盘不再挂在 DSH 服务器的进程树下。这样以后执行 `/orca 关闭`（按进程树
 *  关闭服务器）时，不会顺手把托盘图标一起关掉。
 */
function startTray() {
  if (!existsSync(APP_EXE)) return false
  try {
    const child = spawn('cmd.exe', ['/c', 'start', '', '/b', APP_EXE, '--tray'], {
      windowsHide: true,
      detached: true,
      stdio: 'ignore',
    })
    child.unref()
    return true
  } catch {
    // 极端情况下退回直接启动（仍能用，只是会挂在 DSH 进程树下）
    try {
      const child = spawn(APP_EXE, ['--tray'], { windowsHide: true, detached: true, stdio: 'ignore' })
      child.unref()
      return true
    } catch {
      return false
    }
  }
}

/* ------------------------------------------------------------
 * /orca 命令：子命令一律转发给 C# 命令行工具
 * ---------------------------------------------------------- */
async function orcaHandler(invocation) {
  const raw = (invocation.rawInput || '').trim()
  const sub = raw.split(/\s+/)[0] || 'help'
  return callCli(sub)
}

/* ------------------------------------------------------------
 * 插件入口
 *
 * ⚠️ Cordis 要求插件显式声明 inject 才能访问 ctx.commands，
 *    所以这里用「对象插件」形式导出 { name, inject, apply }。
 * ---------------------------------------------------------- */
function apply(ctx) {
  const cfg = loadConfig()

  // 1. 启动后立即检查更新（后台跑，不阻塞启动）
  void backgroundUpdateCheck(ctx)

  // 2. 按配置自动拉起 Orca 托盘（失败静默）
  if (cfg.trayAutoStart !== false) {
    startTray()
  }

  // 3. 注册 /orca 命令
  ctx.commands.register({
    name: 'orca',
    description: 'Orca DSH Launcher：查看状态 / 检查更新 / 启停服务器 / 日志端口 / 打开界面 / 控制托盘',
    input: { hint: '状态 | 检查 | 更新 | 启动 | 关闭 | 重启 | 打开 | 日志 | 端口 | 配置 | 诊断 | 控制台 | 托盘 | 帮助' },
    handler: (invocation) => orcaHandler(invocation),
  })

  // 4. 每天自动检查一次更新（不打扰，只写状态文件和日志）
  const dailyCheck = setInterval(() => {
    void backgroundUpdateCheck(ctx)
  }, 24 * 60 * 60 * 1000)
  if (dailyCheck.unref) dailyCheck.unref()

  ctx.logger?.info('[orca-dsh-launcher] 已注册命令 /orca（桌面端：C# / .NET 8）')

  // 返回清理函数：插件卸载 / 热重载时停掉定时器
  return () => {
    clearInterval(dailyCheck)
  }
}

const plugin = {
  name: 'orca-dsh-launcher',
  inject: ['commands'],
  apply,
}

export { apply }
export default plugin
