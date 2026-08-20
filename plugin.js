/**
 * ============================================================
 *  Orca DSH Launcher —— DSH 三合一启动器插件
 * ============================================================
 *
 * 【这个插件是干什么的】
 *   把原来两个独立的小工具合并成一个插件：
 *     1. 更新检查（原 dsh-update-checker 插件）
 *        —— 每次 DSH 启动时，自动对比本地代码版本和 GitHub 官方
 *           最新版本，有更新就记录 + 记日志，绝不自动更新。
 *     2. 服务器启停（原 Orca 托盘的一部分）
 *        —— 通过 /orca 命令可以直接启动 / 关闭 DSH 服务器、
 *           打开界面，不用再去点托盘。
 *     3. Orca 托盘（原 dsh-tray.ps1）
 *        —— 桌面右下角的虎鲸图标，随插件打包，DSH 启动时自动
 *           拉起；负责开机常驻、弹更新通知、快速开关服务器。
 *
 * 【工作原理（4 步）】
 *   1. 读配置 ~/.dsh/orca-dsh-launcher.json（没有就用默认值）
 *   2. 启动时后台检查更新（git 对比本地提交号 vs 官方 master）
 *   3. 按配置自动拉起 Orca 托盘（可关闭）
 *   4. 注册 /orca 斜杠命令，提供状态 / 检查 / 启动 / 关闭 /
 *      打开 / 托盘 等子命令
 *
 * 【它绝不做什么】
 *   - 绝不自动更新 DSH
 *   - 绝不改动 DSH 的任何源码文件
 *   - 所有失败都静默跳过，绝不影响 DSH 正常使用
 *
 * 【作者注】
 *   本文件由 AI 助手编写，全部中文注释，方便任何人阅读。
 * ============================================================
 */

import { execFile, spawn } from 'node:child_process'
import { promisify } from 'node:util'
import { fileURLToPath } from 'node:url'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { homedir } from 'node:os'
import net from 'node:net'

const execFileAsync = promisify(execFile)

/* ------------------------------------------------------------
 * 配置区（默认值；用户可改 ~/.dsh/orca-dsh-launcher.json 覆盖）
 * ---------------------------------------------------------- */
const DEFAULT_CONFIG = {
  // 本地 DSH 源码目录
  dshDir: 'D:\\deepseek harness',
  // DSH Web 界面端口
  port: 3080,
  // 官方 GitHub 仓库
  repo: 'deepseek-ai/deepseek-harness',
  // 检查哪个分支
  branch: 'master',
  // 查一次 GitHub 最多等多少毫秒
  checkTimeoutMs: 8000,
  // DSH 启动时是否自动拉起 Orca 托盘
  trayAutoStart: true,
}

// 配置文件名（放 DSH 主目录下）
const CONFIG_FILE = 'orca-dsh-launcher.json'
// 更新检查结果存到哪（与旧插件同一文件名，兼容已有读取方）
const STATE_FILE = 'update-check-state.json'

function configPath() {
  return join(homedir(), '.dsh', CONFIG_FILE)
}

function statePath() {
  return join(homedir(), '.dsh', STATE_FILE)
}

/** 读取配置：文件不存在/损坏 → 用默认值，并尝试写一份默认配置方便用户改 */
function loadConfig() {
  try {
    const raw = readFileSync(configPath(), 'utf8')
    const parsed = JSON.parse(raw)
    return { ...DEFAULT_CONFIG, ...parsed }
  } catch {
    try {
      mkdirSync(join(homedir(), '.dsh'), { recursive: true })
      writeFileSync(configPath(), JSON.stringify(DEFAULT_CONFIG, null, 2), 'utf8')
    } catch { /* 写不进去就算了 */ }
    return { ...DEFAULT_CONFIG }
  }
}

/* ------------------------------------------------------------
 * 更新检查（原 dsh-update-checker 插件逻辑，原样保留）
 * ---------------------------------------------------------- */

/** 第 1 步：读本地 DSH 的提交号 */
async function getLocalCommit(cfg) {
  try {
    const { stdout } = await execFileAsync('git', ['rev-parse', 'HEAD'], {
      cwd: cfg.dshDir,
      timeout: cfg.checkTimeoutMs,
    })
    return stdout.trim()
  } catch {
    return null // 读不到就算了，不报错
  }
}

/** 第 2 步：联网查 GitHub 官方最新提交号 */
async function getRemoteCommit(cfg) {
  try {
    const { stdout } = await execFileAsync('git', [
      'ls-remote',
      'https://github.com/' + cfg.repo + '.git',
      'refs/heads/' + cfg.branch,
    ], {
      timeout: cfg.checkTimeoutMs,
    })
    const sha = stdout.trim().split(/\s+/)[0]
    return sha || null
  } catch {
    return null // 网络不通就算了，安静跳过
  }
}

/** 第 3 步：对比并记录结果 */
async function checkUpdate(ctx, cfg) {
  const local = await getLocalCommit(cfg)
  const remote = await getRemoteCommit(cfg)

  const now = new Date().toISOString()

  // 情况 A：网络失败或读不到本地版本 → 静默跳过
  if (!local || !remote) {
    ctx.logger?.warn('[orca-dsh-launcher] 检查更新失败（本地或网络不可用），已安静跳过')
    return null
  }

  const hasUpdate = local !== remote

  // 记录检查结果（存成 JSON，/orca 命令从这里读）
  const state = {
    checkedAt: now,
    localCommit: local,
    remoteCommit: remote,
    hasUpdate: hasUpdate,
    summary: hasUpdate
      ? '官方发布了新版本，快去看看吧！'
      : '当前已是最新版本',
  }

  try {
    mkdirSync(join(homedir(), '.dsh'), { recursive: true })
    writeFileSync(statePath(), JSON.stringify(state, null, 2), 'utf8')
  } catch (e) {
    ctx.logger?.warn('[orca-dsh-launcher] 保存检查结果失败（不影响使用）')
    return null
  }

  if (hasUpdate) {
    ctx.logger?.info('[orca-dsh-launcher] 🎉 发现 DSH 新版本！官方已更新到 ' + remote.slice(0, 10) + '，本地是 ' + local.slice(0, 10))
  } else {
    ctx.logger?.info('[orca-dsh-launcher] 当前已是最新版本 (' + local.slice(0, 10) + ')')
  }
  return state
}

/** 读取上次检查结果（供 /orca 命令展示） */
async function readLastResult() {
  try {
    const raw = readFileSync(statePath(), 'utf8')
    return JSON.parse(raw)
  } catch {
    return null // 还没检查过，或文件读不到
  }
}

/* ------------------------------------------------------------
 * 服务器控制（原 Orca 托盘的一部分，移植到插件里）
 * ---------------------------------------------------------- */

/** 探测 DSH 服务器是否在运行（连一下端口就知道） */
async function isServerRunning(cfg) {
  return new Promise((resolve) => {
    const sock = net.connect({ host: '127.0.0.1', port: cfg.port })
    const done = (ok) => { sock.destroy(); resolve(ok) }
    sock.setTimeout(1500, () => done(false))
    sock.once('connect', () => done(true))
    sock.once('error', () => done(false))
  })
}

/** 找到监听端口上的进程 PID（netstat 解析，只负责拿 PID） */
async function getServerPid(cfg) {
  const owner = await getPortOwner(cfg)
  return owner ? owner.pid : null
}

/** 找到监听端口上的进程详情（PID/名称/命令行），没有返回 null */
async function getPortOwner(cfg) {
  try {
    const { stdout } = await execFileAsync('netstat', ['-ano'], {
      timeout: 8000,
      windowsHide: true,
    })
    const portStr = ':' + cfg.port
    let pid = null
    for (const line of stdout.split(/\r?\n/)) {
      const m = line.trim().split(/\s+/)
      // 格式：协议 本地地址 外部地址 状态 PID
      if (m.length >= 5 && m[1] && m[1].endsWith(portStr) && m[3] === 'LISTENING') {
        const n = Number(m[4])
        if (Number.isInteger(n) && n > 0) { pid = n; break }
      }
    }
    if (!pid) return null

    // 用 PowerShell 取进程名和命令行（比 tasklist 更能判断是不是 DSH）
    const ps = "Get-CimInstance Win32_Process -Filter \"ProcessId=" + pid + "\" | Select-Object -First 1 Name,CommandLine | ConvertTo-Json -Compress"
    const { stdout: info } = await execFileAsync('powershell.exe', ['-NoProfile', '-Command', ps], {
      timeout: 8000,
      windowsHide: true,
    })
    const parsed = JSON.parse(info || '{}')
    return {
      pid,
      name: String(parsed.Name || ''),
      commandLine: String(parsed.CommandLine || ''),
    }
  } catch {
    // 查不到进程详情时，至少返回 PID，让调用方可以按“未知占用者”处理
    try {
      const { stdout } = await execFileAsync('netstat', ['-ano'], {
        timeout: 8000,
        windowsHide: true,
      })
      const portStr = ':' + cfg.port
      for (const line of stdout.split(/\r?\n/)) {
        const m = line.trim().split(/\s+/)
        if (m.length >= 5 && m[1] && m[1].endsWith(portStr) && m[3] === 'LISTENING') {
          const n = Number(m[4])
          if (Number.isInteger(n) && n > 0) return { pid: n, name: '', commandLine: '' }
        }
      }
    } catch { /* 忽略 */ }
    return null
  }
}

/** 判断端口占用者是不是 DSH（只看命令行特征，避免误伤其他 Node 程序） */
function isDshOwner(owner) {
  if (!owner) return false
  return /pnpm|dsh|deepseek|harness|tsx/i.test(owner.commandLine)
}

/** 等待 DSH 服务器就绪：最多等 timeoutMs 毫秒，每 500ms 查一次 */
async function waitServerRunning(cfg, timeoutMs = 60000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (await isServerRunning(cfg)) return true
    await new Promise((r) => setTimeout(r, 500))
  }
  return isServerRunning(cfg)
}

/** 读 DSH 运行日志尾部（默认 100 行），供聊天命令查看 */
function readServerLogTail(lines = 100) {
  try {
    const logFile = join(homedir(), '.dsh', 'orca-dsh-server.log')
    if (!existsSync(logFile)) return []
    const all = readFileSync(logFile, 'utf8')
    const arr = all.split(/\r?\n/).filter((l) => l.length > 0)
    return arr.length > lines ? arr.slice(-lines) : arr
  } catch {
    return []
  }
}

/** 查一个命令是否存在并返回版本号（失败返回 null） */
async function getCommandVersion(command) {
  try {
    const { stdout } = await execFileAsync('cmd.exe', ['/c', command + ' --version'], {
      timeout: 5000,
      windowsHide: true,
    })
    return String(stdout || '').trim().split(/\r?\n/)[0] || null
  } catch {
    return null
  }
}

/* ------------------------------------------------------------
 * DSH 构建检查（源码 checkout 更新后必须先 build 才能启动）
 *  与 orca-common.ps1 的 Ensure-DshBuilt 逻辑保持一致。
 * ---------------------------------------------------------- */
const DSH_BUILD_ARTIFACTS = [
  'packages/context/session-reference/lib/typert.host.js',
  'packages/context/session-reference/lib/typert.remote-client.js',
  'packages/client/ui-renderer/lib/client.js',
  'packages/client/ui-brand-official/lib/client.js',
  'packages/client/ui-attachment/lib/client.js',
  'packages/client/ui-reference/lib/client.js',
]
const BUILD_CACHE_FILE = join(homedir(), '.dsh', 'orca-dsh-last-build.json')
const BUILD_LOG_FILE = join(homedir(), '.dsh', 'orca-dsh-build.log')

/** 读取本地 DSH 提交号（读不到返回 null） */
async function getDshHead(dir) {
  try {
    const { stdout } = await execFileAsync('git', ['-C', dir, 'rev-parse', 'HEAD'], {
      timeout: 10000,
      windowsHide: true,
    })
    return stdout.trim() || null
  } catch {
    return null
  }
}

function readBuildCache() {
  try { return JSON.parse(readFileSync(BUILD_CACHE_FILE, 'utf8')) } catch { return null }
}

function writeBuildCache(commit) {
  try {
    mkdirSync(join(homedir(), '.dsh'), { recursive: true })
    writeFileSync(BUILD_CACHE_FILE, JSON.stringify({ commit, builtAt: new Date().toISOString() }, null, 2), 'utf8')
  } catch { /* 写不了就算了，下次会重新构建 */ }
}

function buildArtifactsPresent(dir) {
  return DSH_BUILD_ARTIFACTS.every((a) => existsSync(join(dir, a)))
}

/** 执行构建（pnpm.cmd run build，10 分钟超时，输出进构建日志） */
function runDshBuild(dir) {
  return new Promise((resolve) => {
    let child
    try {
      const cmd = 'pnpm.cmd run build >> "' + BUILD_LOG_FILE + '" 2>&1'
      child = spawn('cmd.exe', ['/c', cmd], {
        cwd: dir,
        windowsHide: true,
        detached: true,
        stdio: 'ignore',
      })
    } catch {
      return resolve(false)
    }
    const timer = setTimeout(() => {
      try { child.kill() } catch {}
      resolve(false)
    }, 10 * 60 * 1000)
    child.once('exit', (code) => { clearTimeout(timer); resolve(code === 0) })
    child.once('error', () => { clearTimeout(timer); resolve(false) })
  })
}

/** 构建检查 + 必要时构建；返回 { ok, rebuilt, error } */
async function ensureDshBuilt(cfg) {
  const head = await getDshHead(cfg.dshDir)
  if (!head) return { ok: false, rebuilt: false, error: '无法读取 DSH 提交号（目录不是 git 仓库？）' }
  const cache = readBuildCache()
  const need = !cache || cache.commit !== head || !buildArtifactsPresent(cfg.dshDir)
  if (!need) return { ok: true, rebuilt: false, error: null }
  const built = await runDshBuild(cfg.dshDir)
  if (!built) return { ok: false, rebuilt: false, error: 'DSH 构建失败或超时，详情见 ' + BUILD_LOG_FILE }
  writeBuildCache(head)
  return { ok: true, rebuilt: true, error: null }
}

/** 启动 DSH 服务器（隐藏窗口运行 pnpm dsh web，和托盘行为一致）
 *  先做构建检查：源码更新或缺构建产物时先构建，成功才启动。
 *  返回 { ok, error }，让调用方能告诉用户具体失败原因 */
async function startServer(cfg) {
  if (!existsSync(cfg.dshDir) || !existsSync(join(cfg.dshDir, 'package.json'))) {
    return { ok: false, error: '电脑上未安装 DSH（' + cfg.dshDir + ' 不存在）。请打开 Orca 控制台「安装」页一键安装，或直接启动官方 Web 版：npx @deepseek-ai/dsh web' }
  }
  const build = await ensureDshBuilt(cfg)
  if (!build.ok) {
    return { ok: false, error: build.error }
  }
  try {
    const child = spawn('cmd.exe', ['/c', 'pnpm dsh web'], {
      cwd: cfg.dshDir,
      windowsHide: true,
      detached: true,
      stdio: 'ignore',
    })
    child.unref()
    // 子进程一旦立刻退出，多半是 pnpm 找不到或命令本身失败
    child.once('error', () => {})
    return { ok: true, error: null }
  } catch (e) {
    return { ok: false, error: e.message || '未知错误' }
  }
}

/** 停止 DSH 服务器（连子进程一起结束） */
async function stopServer(pid) {
  try {
    await execFileAsync('taskkill', ['/PID', String(pid), '/T', '/F'], {
      timeout: 10000,
      windowsHide: true,
    })
    return true
  } catch {
    return false
  }
}

/** 打开 DSH 界面（默认浏览器） */
function openUi(cfg) {
  try {
    const child = spawn('cmd.exe', ['/c', 'start', '', 'http://127.0.0.1:' + cfg.port], {
      windowsHide: true,
      detached: true,
      stdio: 'ignore',
    })
    child.unref()
    return true
  } catch {
    return false
  }
}

/* ------------------------------------------------------------
 * Orca 托盘控制（托盘资产随插件打包在 orca/ 目录）
 * ---------------------------------------------------------- */

// 托盘资产目录：本插件文件旁边的 orca\ 文件夹
const PLUGIN_DIR = dirname(fileURLToPath(import.meta.url))
const TRAY_VBS = join(PLUGIN_DIR, 'orca', 'start-tray.vbs')
const TRAY_PS1 = join(PLUGIN_DIR, 'orca', 'dsh-tray.ps1')
const CONSOLE_VBS = join(PLUGIN_DIR, 'orca', 'start-console.vbs')
const CONSOLE_PS1 = join(PLUGIN_DIR, 'orca', 'dsh-console.ps1')

/** 启动托盘：用 wscript 跑 start-tray.vbs（隐藏窗口；托盘自带防重复） */
function startTray() {
  if (!existsSync(TRAY_VBS) || !existsSync(TRAY_PS1)) return false
  try {
    const child = spawn('wscript.exe', [TRAY_VBS], {
      windowsHide: true,
      detached: true,
      stdio: 'ignore',
    })
    child.unref()
    return true
  } catch {
    return false
  }
}

/** 打开控制台窗口：用 wscript 跑 start-console.vbs（独立管理界面） */
function openConsole() {
  if (!existsSync(CONSOLE_VBS) || !existsSync(CONSOLE_PS1)) return false
  try {
    const child = spawn('wscript.exe', [CONSOLE_VBS], {
      windowsHide: true,
      detached: true,
      stdio: 'ignore',
    })
    child.unref()
    return true
  } catch {
    return false
  }
}

/** 停止托盘：按命令行匹配杀掉 dsh-tray.ps1 的 powershell 进程 */
async function stopTray() {
  const ps = "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -match 'dsh-tray\\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
  try {
    await execFileAsync('powershell.exe', ['-NoProfile', '-Command', ps], {
      timeout: 10000,
      windowsHide: true,
    })
    return true
  } catch {
    return false
  }
}

/* ------------------------------------------------------------
 * /orca 斜杠命令（子命令解析）
 * ---------------------------------------------------------- */

const HELP_TEXT = [
  '🐋 Orca DSH Launcher 命令帮助',
  '',
  '  /orca 状态        查看服务器、端口与更新状态',
  '  /orca 检查        立即检查更新',
  '  /orca 启动        启动 DSH 服务器',
  '  /orca 关闭        关闭 DSH 服务器',
  '  /orca 重启        重启 DSH 服务器',
  '  /orca 打开        打开 DSH 界面（未启动会自动启动）',
  '  /orca 日志        查看最近 DSH 运行日志',
  '  /orca 端口        查看端口占用详情',
  '  /orca 配置        查看当前生效配置',
  '  /orca 诊断        一键检查 DSH 环境是否健康',
  '  /orca 控制台      打开控制台管理窗口',
  '  /orca 托盘        启动 Orca 托盘',
  '  /orca 关闭托盘    关闭 Orca 托盘',
  '  /orca 帮助        显示本帮助',
  '',
  '也可用英文：status / check / start / stop / restart / open / log / port / config / health / console / tray / tray-stop / help',
].join('\n')

async function orcaHandler(invocation, ctx) {
  // 每次执行都重新读配置：控制台里改了端口/目录/自启后，聊天命令无需重启 DSH 立即生效
  const cfg = loadConfig()
  const arg = (invocation.rawInput || '').trim().toLowerCase()
  const sub = arg.split(/\s+/)[0] || ''

  switch (sub) {
    case 'status':
    case '状态': {
      const owner = await getPortOwner(cfg)
      const isDsh = owner ? isDshOwner(owner) : false
      const last = await readLastResult()
      const lines = ['🐋 Orca DSH Launcher 状态', '']
      if (isDsh) {
        lines.push('● DSH 服务器：运行中（http://127.0.0.1:' + cfg.port + '）')
      } else if (owner) {
        lines.push('⚠️ 端口 ' + cfg.port + ' 被其他程序占用：' + (owner.name || ('PID ' + owner.pid)))
        lines.push('   当前不是 DSH 在运行，请先处理占用。')
      } else {
        if (!existsSync(join(cfg.dshDir, 'package.json'))) {
          lines.push('○ DSH 服务器：未运行（电脑上未安装 DSH：' + cfg.dshDir + '）')
          lines.push('   请打开 Orca 控制台「安装」页一键安装，或直接启动官方 Web 版：npx @deepseek-ai/dsh web')
        } else {
          lines.push('○ DSH 服务器：未运行')
        }
      }
      if (last) {
        lines.push(last.hasUpdate
          ? '🎉 更新：有新版本（官方 ' + last.remoteCommit.slice(0, 10) + ' / 本地 ' + last.localCommit.slice(0, 10) + '）'
          : '✅ 更新：当前已是最新版本（' + last.localCommit.slice(0, 10) + '）')
        lines.push('检查时间：' + last.checkedAt)
      } else {
        lines.push('更新：还没有检查结果（DSH 刚启动可稍后重试，或 /orca 检查）')
      }
      return { kind: 'success', text: lines.join('\n') }
    }

    case 'check':
    case '检查':
    case 'update': {
      const state = await checkUpdate(ctx, cfg)
      if (!state) {
        return { kind: 'success', text: '检查完成，但没拿到结果（网络或本地版本读取失败），请稍后再试。' }
      }
      if (state.hasUpdate) {
        return {
          kind: 'success',
          text: '🎉 有更新！\n官方最新版本：' + state.remoteCommit.slice(0, 10) + '\n你当前版本：' + state.localCommit.slice(0, 10) + '\n检查时间：' + state.checkedAt + '\n\n（提示：是否更新、怎么更新，请咨询懂技术的人，本插件不自动更新）',
        }
      }
      return { kind: 'success', text: '✅ 当前已是最新版本（' + state.localCommit.slice(0, 10) + '），检查时间：' + state.checkedAt }
    }

    case 'start':
    case '启动': {
      const owner = await getPortOwner(cfg)
      if (owner && isDshOwner(owner)) {
        return { kind: 'success', text: 'DSH 服务器已经在运行中（http://127.0.0.1:' + cfg.port + '）。' }
      }
      if (owner) {
        return { kind: 'error', text: '端口 ' + cfg.port + ' 被 ' + (owner.name || ('PID ' + owner.pid)) + ' 占用，不能启动 DSH。请先关闭占用程序或修改端口。' }
      }
      const result = await startServer(cfg)
      return result.ok
        ? { kind: 'success', text: '已启动 DSH 服务器（后台运行），稍后可在浏览器打开 http://127.0.0.1:' + cfg.port }
        : { kind: 'error', text: '启动 DSH 服务器失败：' + (result.error || '未知原因') }
    }

    case 'stop':
    case '关闭': {
      const owner = await getPortOwner(cfg)
      if (!owner) {
        return { kind: 'success', text: 'DSH 服务器当前未运行，无需关闭。' }
      }
      if (!isDshOwner(owner)) {
        return { kind: 'error', text: '端口 ' + cfg.port + ' 被 ' + (owner.name || ('PID ' + owner.pid)) + ' 占用，不是 DSH，已取消关闭。' }
      }
      // 稍等片刻再动手，让这条回复先显示出来
      setTimeout(() => { void stopServer(owner.pid) }, 800)
      return { kind: 'success', text: '已请求关闭 DSH 服务器（PID ' + owner.pid + '），界面稍后会断开。' }
    }

    case 'restart':
    case '重启': {
      const owner = await getPortOwner(cfg)
      if (owner && !isDshOwner(owner)) {
        return { kind: 'error', text: '端口 ' + cfg.port + ' 被 ' + (owner.name || ('PID ' + owner.pid)) + ' 占用，不是 DSH，不能重启。' }
      }
      if (owner) {
        const stopped = await stopServer(owner.pid)
        if (!stopped) {
          return { kind: 'error', text: '关闭旧 DSH 进程失败（PID ' + owner.pid + '），请稍后再试。' }
        }
        // 等端口释放，避免立刻启动冲突
        await new Promise((r) => setTimeout(r, 1200))
      }
      const result = await startServer(cfg)
      return result.ok
        ? { kind: 'success', text: '已重启 DSH 服务器（后台运行），稍后可在浏览器打开 http://127.0.0.1:' + cfg.port }
        : { kind: 'error', text: '重启失败：' + (result.error || '未知原因') }
    }

    case 'open':
    case '打开': {
      const owner = await getPortOwner(cfg)
      if (owner && !isDshOwner(owner)) {
        return { kind: 'error', text: '端口 ' + cfg.port + ' 被 ' + (owner.name || ('PID ' + owner.pid)) + ' 占用，不能打开 DSH 界面。' }
      }
      if (!owner) {
        const result = await startServer(cfg)
        if (!result.ok) {
          return { kind: 'error', text: '启动 DSH 服务器失败：' + (result.error || '未知原因') }
        }
        // 构建可能需要 1-2 分钟，等待时间放宽到 3 分钟
        if (!(await waitServerRunning(cfg, 180000))) {
          return { kind: 'error', text: 'DSH 服务器启动超时，请到控制台查看日志。' }
        }
      }
      const ok = openUi(cfg)
      return ok
        ? { kind: 'success', text: '已尝试在浏览器打开 DSH 界面（http://127.0.0.1:' + cfg.port + '）。' }
        : { kind: 'error', text: '打开界面失败。' }
    }

    case 'log':
    case '日志': {
      const lines = readServerLogTail(30)
      if (lines.length === 0) {
        return { kind: 'success', text: '还没有日志（服务器可能从未启动过，或日志文件不存在）。' }
      }
      return { kind: 'success', text: '📄 最近 DSH 日志（最后 ' + lines.length + ' 行）：\n' + lines.join('\n') }
    }

    case 'port':
    case '端口': {
      const owner = await getPortOwner(cfg)
      if (!owner) {
        return { kind: 'success', text: '端口 ' + cfg.port + ' 空闲，DSH 服务器未运行。' }
      }
      if (isDshOwner(owner)) {
        return { kind: 'success', text: '端口 ' + cfg.port + ' 由 DSH 占用（PID ' + owner.pid + '，' + owner.name + '）。' }
      }
      return { kind: 'success', text: '⚠️ 端口 ' + cfg.port + ' 被其他程序占用：' + (owner.name || '未知程序') + '（PID ' + owner.pid + '）。' }
    }

    case 'config':
    case '配置': {
      return {
        kind: 'success',
        text: '🐋 当前配置\n'
          + '· DSH 目录：' + cfg.dshDir + '\n'
          + '· 端口：' + cfg.port + '\n'
          + '· 仓库：' + cfg.repo + '\n'
          + '· 分支：' + cfg.branch + '\n'
          + '· 网络超时：' + cfg.checkTimeoutMs + 'ms\n'
          + '· DSH 启动时自动拉起托盘：' + (cfg.trayAutoStart ? '开' : '关'),
      }
    }

    case 'health':
    case 'diagnose':
    case '诊断':
    case '体检': {
      const owner = await getPortOwner(cfg)
      const lines = ['🐋 Orca DSH Launcher 诊断', '']
      lines.push('· DSH 目录：' + cfg.dshDir + (existsSync(cfg.dshDir) ? '  ✅ 存在' : '  ❌ 不存在'))
      if (owner && isDshOwner(owner)) {
        lines.push('· 端口 ' + cfg.port + '：✅ DSH 正在运行')
      } else if (owner) {
        lines.push('· 端口 ' + cfg.port + '：⚠️ 被 ' + (owner.name || ('PID ' + owner.pid)) + ' 占用（不是 DSH）')
      } else {
        lines.push('· 端口 ' + cfg.port + '：○ 空闲（DSH 未运行）')
      }
      const [pnpm, git] = await Promise.all([
        getCommandVersion('pnpm'),
        getCommandVersion('git'),
      ])
      lines.push('· pnpm：' + (pnpm ? '✅ ' + pnpm : '❌ 未找到（启动 DSH 需要）'))
      lines.push('· git：' + (git ? '✅ ' + git : '❌ 未找到（更新检查需要）'))
      const local = await getLocalCommit(cfg)
      lines.push('· 本地 DSH 版本：' + (local ? local.slice(0, 10) : '❌ 读取失败（目录不是 git 仓库？）'))
      return { kind: 'success', text: lines.join('\n') }
    }

    case 'tray':
    case '托盘': {
      const ok = startTray()
      return ok
        ? { kind: 'success', text: '已拉起 Orca 托盘（右下角虎鲸图标）。' }
        : { kind: 'error', text: '启动 Orca 托盘失败（托盘文件缺失？）。' }
    }

    case 'console':
    case '控制台': {
      const ok = openConsole()
      return ok
        ? { kind: 'success', text: '已打开 Orca 控制台窗口（独立管理界面）。' }
        : { kind: 'error', text: '打开控制台失败（文件缺失？）。' }
    }

    case 'tray-stop':
    case 'trayoff':
    case '关闭托盘': {
      const ok = await stopTray()
      return ok
        ? { kind: 'success', text: '已关闭 Orca 托盘。' }
        : { kind: 'success', text: '没有找到正在运行的 Orca 托盘（或已关闭）。' }
    }

    case '':
    case 'help':
    case '帮助':
      return { kind: 'success', text: HELP_TEXT }

    default:
      return { kind: 'success', text: '未知子命令「' + sub + '」。\n\n' + HELP_TEXT }
  }
}

/* ------------------------------------------------------------
 * 插件入口：DSH (Cordis) 加载插件时自动调用 apply
 *
 * ⚠️ 重要：Cordis 要求插件显式声明 inject（依赖注入）才能访问
 *     ctx.commands 等服务，所以这里用「对象插件」形式导出：
 *     { name, inject: ['commands'], apply }。
 *     只导出裸函数/裸对象会导致 "cannot get property without inject"。
 * ---------------------------------------------------------- */
function apply(ctx) {
  const cfg = loadConfig()

  // 1. 启动后立即检查更新（后台跑，不阻塞启动）
  checkUpdate(ctx, cfg)

  // 2. 按配置自动拉起 Orca 托盘（失败静默，不影响 DSH）
  if (cfg.trayAutoStart) {
    startTray()
  }

  // 3. 注册 /orca 命令（inject: ['commands'] 已保证 ctx.commands 可用）
  ctx.commands.register({
    name: 'orca',
    description: 'Orca DSH Launcher：查看状态 / 检查更新 / 启停服务器 / 日志端口 / 打开界面 / 控制托盘',
    input: { hint: '状态 | 检查 | 启动 | 关闭 | 重启 | 打开 | 日志 | 端口 | 配置 | 诊断 | 托盘 | 帮助' },
    handler: (invocation) => orcaHandler(invocation, ctx),
  })

  // 4. 每天自动检查一次更新（不阻塞、不打扰，只写状态文件和日志）
  const dailyCheck = setInterval(() => {
    checkUpdate(ctx, loadConfig())
  }, 24 * 60 * 60 * 1000)
  if (dailyCheck.unref) dailyCheck.unref()

  ctx.logger?.info('[orca-dsh-launcher] 已注册命令 /orca')

  // 返回清理函数：插件卸载/热重载时停止每日定时器，避免泄漏
  return () => {
    clearInterval(dailyCheck)
  }
}

// 对象插件形式（loader 的 unwrapExports 取 default 导出，并读取 plugin.inject）
const plugin = {
  name: 'orca-dsh-launcher',
  inject: ['commands'],
  apply,
}

export { apply }
export default plugin
