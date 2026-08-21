/**
 * 验证 Cordis inject 语义修复：模拟 Cordis 的 Proxy get 陷阱，
 * 确认带 inject: ['commands'] 的对象插件可正常访问 ctx.commands。
 */
import plugin from '../plugin.js'

// 模拟 Cordis Context 的 Proxy get 陷阱
// - logger 是 Cordis 内置服务，直接挂在 target 上（无需 inject）
// - 其他属性仅在 inject 声明后可访问，否则抛 "without inject"
const injected = new Set(plugin.inject || [])
let registeredName = null
const target = { logger: { info: () => {}, warn: () => {} } }
const ctx = new Proxy(target, {
  get(t, prop) {
    if (prop in t) return t[prop]
    if (injected.has(prop)) {
      if (prop === 'commands') {
        return { register: (d) => { registeredName = d.name } }
      }
      return undefined
    }
    throw new Error(`cannot get property "${prop}" without inject`)
  },
})

// 临时关托盘自启，避免测试拉起托盘；测试结束会恢复原配置
import { writeFileSync, mkdirSync, readFileSync, existsSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
const orcaCfgPath = join(homedir(), '.dsh', 'orca-dsh-launcher.json')
const hadOldConfig = existsSync(orcaCfgPath)
const oldConfigContent = hadOldConfig ? readFileSync(orcaCfgPath, 'utf8') : null
mkdirSync(join(homedir(), '.dsh'), { recursive: true })
writeFileSync(orcaCfgPath, JSON.stringify({ trayAutoStart: false }, null, 2), 'utf8')
function restoreOrcaConfig() {
  try {
    if (hadOldConfig) {
      writeFileSync(orcaCfgPath, oldConfigContent, 'utf8')
    } else {
      rmSync(orcaCfgPath, { force: true })
    }
  } catch {}
}
process.on('exit', restoreOrcaConfig)

try {
  plugin.apply(ctx)
  console.log('apply OK, registered command:', registeredName)
  console.log('INJECT TEST PASSED ✓')
  process.exit(0)
} catch (e) {
  console.error('INJECT TEST FAILED:', e.message)
  process.exit(1)
}
