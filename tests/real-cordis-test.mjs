/**
 * ============================================================
 *  真实 Cordis 加载验证（tests/real-cordis-test.mjs）
 * ============================================================
 *  用 DSH 实际使用的 @deepseek-ai/cordis 运行时创建真实 Context，
 *  提供最小 commands 服务，再按 DSH loader 的方式加载 plugin.js，
 *  最后真的调一次 /orca 状态 handler。
 *
 *  这是最接近 DSH 真实加载路径的测试：
 *    - inject 声明写错会复现 "cannot get property without inject"
 *    - handler 返回值结构不对会立刻暴露
 *    - orca-cli.exe 缺失/参数不对也会在这里发现
 *
 *  用法：node tests/real-cordis-test.mjs
 *  找不到 cordis 运行时（没装 DSH 完整版）时会跳过并返回 0。
 * ============================================================
 */

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { pathToFileURL } from 'node:url'

/* ---------- 1. 找 DSH 里的 cordis 运行时 ---------- */
const cfgPath = join(homedir(), '.dsh', 'orca-dsh-launcher.json')
let dshDir = 'D:\\deepseek harness'
try {
  const cfg = JSON.parse(readFileSync(cfgPath, 'utf8'))
  if (cfg.dshDir) dshDir = cfg.dshDir
} catch { /* 用默认值 */ }

const cordisEntry = join(dshDir, 'vendor', 'cordis', 'lib', 'index.js')
if (!existsSync(cordisEntry)) {
  console.log('[跳过] 找不到 cordis 运行时：' + cordisEntry)
  console.log('       （没装 DSH 完整版时跳过本项，不算失败）')
  process.exit(0)
}

/* ---------- 2. 测试期间临时关掉托盘自启，结束后恢复原配置 ---------- */
const hadOldConfig = existsSync(cfgPath)
const oldConfigContent = hadOldConfig ? readFileSync(cfgPath, 'utf8') : null
mkdirSync(join(homedir(), '.dsh'), { recursive: true })
const testConfig = hadOldConfig ? { ...JSON.parse(oldConfigContent), trayAutoStart: false } : { trayAutoStart: false }
writeFileSync(cfgPath, JSON.stringify(testConfig, null, 2), 'utf8')
function restoreConfig() {
  try {
    if (hadOldConfig) writeFileSync(cfgPath, oldConfigContent, 'utf8')
    else rmSync(cfgPath, { force: true })
  } catch { /* 忽略 */ }
}
process.on('exit', restoreConfig)

/* ---------- 3. 真实 Cordis + 最小 commands 服务 ---------- */
const { Context, Service } = await import(pathToFileURL(cordisEntry).href)
const { default: plugin } = await import(pathToFileURL(join(import.meta.dirname, '..', 'plugin.js')).href)

class FakeCommands extends Service {
  constructor(ctx) {
    super(ctx, 'commands')
    this.registered = []
  }

  register(def) {
    this.registered.push(def)
    return () => {}
  }
}

const ctx = new Context()
new FakeCommands(ctx)

try {
  // 与 DSH loader 相同路径：default 导出 → ctx.plugin() → await fiber
  const fiber = ctx.plugin(plugin)
  await fiber
  console.log('[OK] 插件加载成功（真实 Cordis 运行时）')

  const names = ctx.commands.registered.map((d) => d.name)
  console.log('[OK] 已注册命令：' + names.join(', '))

  const def = ctx.commands.registered.find((d) => d.name === 'orca')
  if (!def) throw new Error('未找到 /orca 命令')

  const r = await def.handler({
    rawInput: ' 状态',
    commandId: 'test',
    agent: {},
    signal: new AbortController().signal,
  })
  if (!r || typeof r.text !== 'string' || !r.kind) throw new Error('handler 返回值结构不对')
  console.log('[OK] /orca 状态 handler 返回 kind=' + r.kind)
  console.log(r.text.split('\n').slice(0, 4).map((l) => '     ' + l).join('\n'))

  console.log('REAL CORDIS LOAD TEST PASSED')
  process.exit(0)
} catch (e) {
  console.error('REAL CORDIS LOAD TEST FAILED: ' + (e && e.message ? e.message : String(e)))
  process.exit(1)
}
