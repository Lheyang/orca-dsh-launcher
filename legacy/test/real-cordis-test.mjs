/**
 * 真实 Cordis 加载验证：
 * 用 DSH 实际使用的 @deepseek-ai/cordis 运行时（vendor/cordis/lib），
 * 创建真实 Context + 提供 commands 服务，然后按 DSH loader 的方式
 * （unwrapExports → ctx.plugin）加载 orca-dsh-launcher 插件。
 *
 * 如果 inject 声明有问题，这里会复现 "cannot get property without inject"。
 */
import { Context, Service } from 'file:///D:/deepseek%20harness/vendor/cordis/lib/index.js'
import plugin from '../plugin.js'
import { writeFileSync, mkdirSync, readFileSync, existsSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'

// 临时关托盘自启，避免测试拉起托盘；测试结束会恢复原配置
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

// 最小 commands 服务（真实 Cordis Service 子类，注册为 'commands'）
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
  // 与 DSH loader 相同路径：取 default 导出 → ctx.plugin() → await fiber
  const fiber = ctx.plugin(plugin)
  await fiber
  console.log('✓ 插件加载成功（真实 Cordis 运行时）')

  const commands = ctx.commands
  const names = commands.registered.map((d) => d.name)
  console.log('✓ 已注册命令:', names.join(', '))

  const def = commands.registered.find((d) => d.name === 'orca')
  if (!def) throw new Error('未找到 /orca 命令')
  const r = await def.handler({ rawInput: ' 状态', commandId: 't', agent: {}, signal: new AbortController().signal })
  console.log('✓ /orca 状态 handler 返回 kind:', r.kind)
  console.log(r.text.split('\n').slice(0, 3).join('\n'))

  console.log('\nREAL CORDIS LOAD TEST PASSED ✓')
  process.exit(0)
} catch (e) {
  console.error('\nREAL CORDIS LOAD TEST FAILED:', e.message)
  process.exit(1)
}
