/**
 * 冒烟测试：验证 Orca DSH Launcher 插件在模拟 DSH ctx 下可正常工作。
 * 运行：node test\smoke.mjs
 * 注意：测试前会把托盘自启临时关掉（trayAutoStart:false），
 *       测试结束会自动恢复原来的配置文件。
 */
import { apply } from '../plugin.js'

const registered = []
const logger = {
  info: (...a) => console.log('[log ]', ...a),
  warn: (...a) => console.log('[warn]', ...a),
}
const ctx = {
  logger,
  commands: {
    register: (def) => { registered.push(def) },
  },
}

// 临时关闭托盘自启，避免测试时真的弹出托盘；测试结束会恢复原配置
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
      // 原本没有配置文件，测试后删掉，避免留下测试痕迹
      rmSync(orcaCfgPath, { force: true })
    }
  } catch {}
}
process.on('exit', restoreOrcaConfig)

apply(ctx)
console.log('registered commands:', registered.map((c) => c.name))

const def = registered[0]
if (!def) { console.error('FAIL: no command registered'); process.exit(1) }

const inv = (rawInput) => ({ rawInput, commandId: 'test', agent: {}, signal: new AbortController().signal })

// 等启动时后台更新检查完成（网络查询可能需要几秒）
setTimeout(async () => {
  try {
    for (const sub of ['帮助', '不存在的子命令', '状态', 'check', '日志', '端口', '配置', '诊断']) {
      console.log('\n========== /orca ' + sub + ' ==========')
      const r = await def.handler(inv(' ' + sub))
      console.log('kind:', r.kind)
      console.log(r.text)
    }
    console.log('\nSMOKE TEST DONE')
    process.exit(0)
  } catch (e) {
    console.error('SMOKE TEST FAIL:', e)
    process.exit(1)
  }
}, 4000)
